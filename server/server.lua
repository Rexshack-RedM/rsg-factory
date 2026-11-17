local RSGCore = exports['rsg-core']:GetCoreObject()

local Factories = {} -- [id] = { id, name, ped_model, x, y, z, h, recipes = {...} }
local Loaded = false

---------------------------------------------------------------------
-- Database
---------------------------------------------------------------------
local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS `rsg_factories` (
      `id` INT NOT NULL AUTO_INCREMENT,
      `name` VARCHAR(64) NOT NULL,
      `ped_model` VARCHAR(64) NOT NULL,
      `x` DOUBLE NOT NULL,
      `y` DOUBLE NOT NULL,
      `z` DOUBLE NOT NULL,
      `h` DOUBLE NOT NULL DEFAULT 0,
      `recipes` LONGTEXT NOT NULL,
      `created_by` VARCHAR(50) DEFAULT NULL,
      PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `rsg_factory_queue` (
      `id` INT NOT NULL AUTO_INCREMENT,
      `factory_id` INT NOT NULL,
      `citizenid` VARCHAR(50) NOT NULL,
      `label` VARCHAR(64) NOT NULL,
      `outputs` LONGTEXT NOT NULL,
      `finish_at` BIGINT NOT NULL,
      `stages` LONGTEXT DEFAULT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_factory_citizen` (`factory_id`, `citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

local function ensureDatabase()
    for i = 1, #SCHEMA do
        local ok, err = pcall(MySQL.query.await, SCHEMA[i])
        if not ok then
            print(('^1[rsg-factory] database setup failed: %s^7'):format(tostring(err)))
            return false
        end
    end
    -- safe upgrade for tables created by v1.0.0 (adds the chain stages column)
    local ok, err = pcall(function()
        local has = MySQL.scalar.await(
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'rsg_factory_queue' AND COLUMN_NAME = 'stages'")
        if (has or 0) == 0 then
            MySQL.query.await('ALTER TABLE `rsg_factory_queue` ADD COLUMN `stages` LONGTEXT DEFAULT NULL')
        end
    end)
    if not ok then
        print(('^1[rsg-factory] database upgrade failed: %s^7'):format(tostring(err)))
        return false
    end
    print('^2[rsg-factory] database tables ready^7')
    return true
end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function notify(src, key, ntype, ...)
    TriggerClientEvent('RSGCore:Client:Notify', src, {
        title = locale('notify_title'),
        description = locale(key, ...),
        type = ntype or 'inform',
    })
end

local function isAdmin(src)
    return RSGCore.Functions.HasPermission(src, Config.AdminPermission) and true or false
end

local function nearFactory(src, f, extra)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    return #(GetEntityCoords(ped) - vector3(f.x, f.y, f.z)) <= (Config.InteractDistance + (extra or 2.0))
end

local function cleanText(s, max)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('%c', '')
    s = s:gsub('^%s+', '')
    s = s:gsub('%s+$', '')
    if #s < 1 or #s > max then return nil end
    return s
end

local function itemLabel(name)
    local it = RSGCore.Shared.Items[name]
    return it and it.label or name
end

local function decorate(list)
    local out = {}
    for i = 1, #list do
        out[i] = { item = list[i].item, amount = list[i].amount, label = itemLabel(list[i].item) }
    end
    return out
end

local function sanitizeList(list)
    if type(list) ~= 'table' or #list < 1 or #list > Config.MaxItemsPerRecipe then return nil end
    local out, seen = {}, {}
    for i = 1, #list do
        local e = list[i]
        if type(e) ~= 'table' or type(e.item) ~= 'string' then return nil end
        local amount = math.floor(tonumber(e.amount) or 0)
        if not RSGCore.Shared.Items[e.item] or seen[e.item] or amount < 1 or amount > Config.MaxAmount then
            return nil
        end
        seen[e.item] = true
        out[#out + 1] = { item = e.item, amount = amount }
    end
    return out
end

-- returns recipes, or nil + reason ('data' | 'chain')
local function sanitizeRecipes(raw)
    if type(raw) ~= 'table' or #raw > Config.MaxRecipes then return nil, 'data' end
    local out = {}
    for i = 1, #raw do
        local r = raw[i]
        if type(r) ~= 'table' then return nil, 'data' end
        local label = cleanText(r.label, 48)
        local inputs = sanitizeList(r.inputs)
        local outputs = sanitizeList(r.outputs)
        local time = math.floor(tonumber(r.time) or 0)
        local nextIdx = math.floor(tonumber(r.next) or 0)
        if not label or not inputs or not outputs or nextIdx < 0 then return nil, 'data' end
        if time < Config.MinTime or time > Config.MaxTime then return nil, 'data' end
        local job = nil
        if type(r.job) == 'string' and r.job ~= '' then
            if #r.job > 32 or not r.job:match('^[%w_%-]+$') then return nil, 'data' end
            job = r.job
        end
        out[#out + 1] = {
            label = label, inputs = inputs, outputs = outputs, time = time, job = job,
            next = nextIdx > 0 and nextIdx or nil,
        }
    end

    -- chains: next must exist, differ from itself and consume something the line outputs
    for i, r in ipairs(out) do
        if r.next then
            local nxt = out[r.next]
            if not nxt or r.next == i then return nil, 'chain' end
            local shares = false
            for _, o in ipairs(r.outputs) do
                for _, inp in ipairs(nxt.inputs) do
                    if o.item == inp.item then shares = true end
                end
            end
            if not shares then return nil, 'chain' end
        end
    end
    -- no loops, and chains no longer than Config.MaxChainLength
    for i = 1, #out do
        local seen, count, cur = {}, 0, i
        while cur do
            if seen[cur] then return nil, 'chain' end
            seen[cur] = true
            count = count + 1
            if count > Config.MaxChainLength then return nil, 'chain' end
            cur = out[cur].next
        end
    end
    return out
end

-- Works out a whole chained run up front.
-- Stage 1 runs `batches`; every later stage runs as many batches as the previous
-- stage's output can feed. Inputs a later stage needs that the previous stage does
-- not make are taken from the player at the start. Surplus and by-products are
-- paid out with the final products.
-- returns { stages = {{label,time,job}}, upfront = {item=amount}, outputs = {{item,amount}}, total } or nil, 'chain'
local function buildPlan(f, startIndex, batches)
    local stages, upfront, extra = {}, {}, {}
    local carry, total = nil, 0
    local idx, b = startIndex, batches
    local guard = 0

    while idx do
        guard = guard + 1
        local r = f.recipes[idx]
        if not r or guard > Config.MaxChainLength then return nil, 'chain' end

        local runs = b
        if carry then
            runs = math.huge
            local shared = false
            for _, e in ipairs(r.inputs) do
                if carry[e.item] then
                    shared = true
                    runs = math.min(runs, math.floor(carry[e.item] / e.amount))
                end
            end
            if not shared or runs < 1 then return nil, 'chain' end
        end

        for _, e in ipairs(r.inputs) do
            if not (carry and carry[e.item]) then
                upfront[e.item] = (upfront[e.item] or 0) + e.amount * runs
            end
        end
        if carry then
            for item, amt in pairs(carry) do
                local used = 0
                for _, e in ipairs(r.inputs) do
                    if e.item == item then used = e.amount * runs end
                end
                if amt - used > 0 then extra[item] = (extra[item] or 0) + (amt - used) end
            end
        end

        stages[#stages + 1] = { label = r.label, time = r.time * runs, job = r.job }
        total = total + r.time * runs

        carry = {}
        for _, o in ipairs(r.outputs) do carry[o.item] = o.amount * runs end
        idx = r.next
    end

    for item, amt in pairs(extra) do carry[item] = (carry[item] or 0) + amt end
    local outputs = {}
    for item, amt in pairs(carry) do outputs[#outputs + 1] = { item = item, amount = amt } end
    table.sort(outputs, function(a, b2) return a.item < b2.item end)
    return { stages = stages, upfront = upfront, outputs = outputs, total = total }
end

local function publicList()
    local list = {}
    for id, f in pairs(Factories) do
        list[#list + 1] = { id = id, name = f.name, ped_model = f.ped_model, x = f.x, y = f.y, z = f.z, h = f.h }
    end
    return list
end

local function broadcast()
    TriggerClientEvent('rsg-factory:client:sync', -1, publicList())
end

local function decorateRecipes(recipes)
    local out = {}
    for i = 1, #recipes do
        local r = recipes[i]
        out[i] = {
            label = r.label, time = r.time, job = r.job, next = r.next or 0,
            inputs = decorate(r.inputs), outputs = decorate(r.outputs),
        }
    end
    return out
end

local function getQueue(citizenid, factoryId)
    local rows = MySQL.query.await(
        'SELECT `id`, `label`, `outputs`, `finish_at`, `stages` FROM `rsg_factory_queue` WHERE `factory_id` = ? AND `citizenid` = ? ORDER BY `finish_at`',
        { factoryId, citizenid }) or {}
    local now = os.time()
    local out = {}
    for i = 1, #rows do
        local outputs = json.decode(rows[i].outputs) or {}

        -- chained runs: when each stage ends (seconds from now)
        local stages, raw = {}, rows[i].stages and json.decode(rows[i].stages) or {}
        local total = 0
        for _, s in ipairs(raw) do total = total + s.time end
        local cursor = rows[i].finish_at - total
        for _, s in ipairs(raw) do
            cursor = cursor + s.time
            stages[#stages + 1] = { label = s.label, endsIn = math.max(0, cursor - now) }
        end

        out[i] = {
            id = rows[i].id,
            label = rows[i].label,
            outputs = decorate(outputs),
            remaining = math.max(0, rows[i].finish_at - now),
            stages = stages,
        }
    end
    return out
end

local function factoryState(src, Player, f)
    return {
        id = f.id,
        name = f.name,
        ped_model = f.ped_model,
        recipes = decorateRecipes(f.recipes),
        queue = getQueue(Player.PlayerData.citizenid, f.id),
        isAdmin = isAdmin(src),
        maxBatches = Config.MaxBatches,
        limits = {
            recipes = Config.MaxRecipes, items = Config.MaxItemsPerRecipe, amount = Config.MaxAmount,
            minTime = Config.MinTime, maxTime = Config.MaxTime,
        },
    }
end

---------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------
CreateThread(function()
    if Config.AutoDatabase and not ensureDatabase() then return end
    local rows = MySQL.query.await('SELECT * FROM `rsg_factories`') or {}
    for i = 1, #rows do
        local row = rows[i]
        local recipes = sanitizeRecipes(json.decode(row.recipes) or {}) or {}
        Factories[row.id] = {
            id = row.id, name = row.name, ped_model = row.ped_model,
            x = row.x, y = row.y, z = row.z, h = row.h, recipes = recipes,
        }
    end
    Loaded = true
    print(('^2[rsg-factory] loaded %d factories^7'):format(#rows))
end)

---------------------------------------------------------------------
-- Admin command: creates the factory where the admin stands
---------------------------------------------------------------------
RSGCore.Commands.Add(Config.CommandName, 'Create a factory at your position (admin)',
    { { name = 'name', help = 'Factory name' } }, false, function(source, args)
        local src = source
        if not isAdmin(src) then return notify(src, 'no_permission', 'error') end
        if not Loaded then return end
        local Player = RSGCore.Functions.GetPlayer(src)
        if not Player then return end

        local name = cleanText(table.concat(args or {}, ' '), 64)
        if not name then return notify(src, 'usage_create', 'error') end

        local ped = GetPlayerPed(src)
        local coords = GetEntityCoords(ped)
        local heading = GetEntityHeading(ped)

        local id = MySQL.insert.await(
            'INSERT INTO `rsg_factories` (`name`, `ped_model`, `x`, `y`, `z`, `h`, `recipes`, `created_by`) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            { name, Config.DefaultPedModel, coords.x, coords.y, coords.z, heading, '[]', Player.PlayerData.citizenid })
        if not id then return notify(src, 'invalid_data', 'error') end

        Factories[id] = {
            id = id, name = name, ped_model = Config.DefaultPedModel,
            x = coords.x, y = coords.y, z = coords.z, h = heading, recipes = {},
        }
        notify(src, 'factory_created', 'success', name)
        broadcast()
        TriggerClientEvent('rsg-factory:client:openAdmin', src, id)
    end, Config.AdminPermission)

---------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------
RSGCore.Functions.CreateCallback('rsg-factory:server:getFactories', function(source, cb)
    if not Loaded then return cb(nil) end
    cb({ factories = publicList(), isAdmin = isAdmin(source) })
end)

RSGCore.Functions.CreateCallback('rsg-factory:server:getFactory', function(source, cb, factoryId)
    local Player = RSGCore.Functions.GetPlayer(source)
    local f = Player and Factories[tonumber(factoryId)]
    if not f then return cb(nil) end
    if not nearFactory(source, f, 8.0) then
        notify(source, 'too_far', 'error')
        return cb(nil)
    end
    cb(factoryState(source, Player, f))
end)

RSGCore.Functions.CreateCallback('rsg-factory:server:getItems', function(source, cb)
    if not isAdmin(source) then return cb(nil) end
    local list = {}
    for name, it in pairs(RSGCore.Shared.Items) do
        list[#list + 1] = { name = name, label = it.label or name }
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    cb(list)
end)

RSGCore.Functions.CreateCallback('rsg-factory:server:saveFactory', function(source, cb, factoryId, data)
    if not isAdmin(source) then notify(source, 'no_permission', 'error') return cb(false) end
    local f = Factories[tonumber(factoryId)]
    if not f then notify(source, 'not_found', 'error') return cb(false) end
    if not nearFactory(source, f, 8.0) then notify(source, 'too_far', 'error') return cb(false) end
    if type(data) ~= 'table' then notify(source, 'invalid_data', 'error') return cb(false) end

    local name = cleanText(data.name, 64)
    local model = cleanText(data.ped_model or '', 64) or Config.DefaultPedModel
    local recipes, why = sanitizeRecipes(data.recipes)
    if not name or not model:match('^[%w_]+$') or not recipes then
        notify(source, why == 'chain' and 'chain_invalid' or 'invalid_data', 'error')
        return cb(false)
    end

    MySQL.update.await('UPDATE `rsg_factories` SET `name` = ?, `ped_model` = ?, `recipes` = ? WHERE `id` = ?',
        { name, model, json.encode(recipes), f.id })
    f.name, f.ped_model, f.recipes = name, model, recipes
    notify(source, 'factory_saved', 'success')
    broadcast()
    cb(true)
end)

RSGCore.Functions.CreateCallback('rsg-factory:server:deleteFactory', function(source, cb, factoryId)
    if not isAdmin(source) then notify(source, 'no_permission', 'error') return cb(false) end
    local f = Factories[tonumber(factoryId)]
    if not f then notify(source, 'not_found', 'error') return cb(false) end
    if not nearFactory(source, f, 8.0) then notify(source, 'too_far', 'error') return cb(false) end

    MySQL.update.await('DELETE FROM `rsg_factory_queue` WHERE `factory_id` = ?', { f.id })
    MySQL.update.await('DELETE FROM `rsg_factories` WHERE `id` = ?', { f.id })
    Factories[f.id] = nil
    notify(source, 'factory_deleted', 'success')
    broadcast()
    cb(true)
end)

RSGCore.Functions.CreateCallback('rsg-factory:server:startProduction', function(source, cb, factoryId, recipeIndex, batches)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    local f = Player and Factories[tonumber(factoryId)]
    local recipe = f and f.recipes[math.floor(tonumber(recipeIndex) or 0)]
    if not recipe then notify(src, 'not_found', 'error') return cb(false) end

    batches = math.floor(tonumber(batches) or 0)
    if batches < 1 or batches > Config.MaxBatches then notify(src, 'invalid_data', 'error') return cb(false) end
    if not nearFactory(src, f) then notify(src, 'too_far', 'error') return cb(false) end

    local plan, perr = buildPlan(f, math.floor(tonumber(recipeIndex)), batches)
    if not plan then
        notify(src, perr == 'chain' and 'chain_too_small' or 'invalid_data', 'error')
        return cb(false)
    end

    -- every stage's job lock must be met
    for _, stage in ipairs(plan.stages) do
        if stage.job then
            local held = exports['rsg-core']:HasPlayerJob(src, stage.job)
            if not held and Player.PlayerData.job.name ~= stage.job then
                notify(src, 'job_required', 'error')
                return cb(false)
            end
        end
    end

    local citizenid = Player.PlayerData.citizenid
    local running = MySQL.scalar.await(
        'SELECT COUNT(*) FROM `rsg_factory_queue` WHERE `factory_id` = ? AND `citizenid` = ?', { f.id, citizenid }) or 0
    if running >= Config.MaxQueuePerPlayer then notify(src, 'queue_full', 'error') return cb(false) end

    for item, amount in pairs(plan.upfront) do
        if not exports['rsg-inventory']:HasItem(src, item, amount) then
            notify(src, 'missing_items', 'error')
            return cb(false)
        end
    end

    local removed = {}
    for item, amount in pairs(plan.upfront) do
        if exports['rsg-inventory']:RemoveItem(src, item, amount, nil, 'rsg-factory:input') then
            removed[#removed + 1] = { item = item, amount = amount }
        else
            for _, r in ipairs(removed) do
                exports['rsg-inventory']:AddItem(src, r.item, r.amount, nil, nil, 'rsg-factory:rollback')
            end
            notify(src, 'missing_items', 'error')
            return cb(false)
        end
    end

    local stages = {}
    for i, s in ipairs(plan.stages) do stages[i] = { label = s.label, time = s.time } end
    MySQL.insert.await(
        'INSERT INTO `rsg_factory_queue` (`factory_id`, `citizenid`, `label`, `outputs`, `finish_at`, `stages`) VALUES (?, ?, ?, ?, ?, ?)',
        { f.id, citizenid, recipe.label, json.encode(plan.outputs), os.time() + plan.total, json.encode(stages) })

    notify(src, 'production_started', 'success', recipe.label, batches)
    cb(true)
end)

RSGCore.Functions.CreateCallback('rsg-factory:server:collect', function(source, cb, factoryId)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    local f = Player and Factories[tonumber(factoryId)]
    if not f then return cb(false) end
    if not nearFactory(src, f) then notify(src, 'too_far', 'error') return cb(false) end

    local rows = MySQL.query.await(
        'SELECT `id`, `outputs` FROM `rsg_factory_queue` WHERE `factory_id` = ? AND `citizenid` = ? AND `finish_at` <= ?',
        { f.id, Player.PlayerData.citizenid, os.time() }) or {}
    if #rows == 0 then notify(src, 'nothing_ready', 'error') return cb(false) end

    local collected, blocked = false, false
    for _, row in ipairs(rows) do
        local outputs = json.decode(row.outputs) or {}
        local canAll = true
        for _, e in ipairs(outputs) do
            if not exports['rsg-inventory']:CanAddItem(src, e.item, e.amount) then canAll = false break end
        end

        if not canAll then
            blocked = true
        else
            -- delete first so a row can never be paid out twice
            local affected = MySQL.update.await('DELETE FROM `rsg_factory_queue` WHERE `id` = ?', { row.id })
            if affected and affected > 0 then
                local leftover = {}
                for _, e in ipairs(outputs) do
                    if not exports['rsg-inventory']:AddItem(src, e.item, e.amount, nil, nil, 'rsg-factory:output') then
                        leftover[#leftover + 1] = e
                    end
                end
                if #leftover > 0 then
                    MySQL.insert.await(
                        'INSERT INTO `rsg_factory_queue` (`factory_id`, `citizenid`, `label`, `outputs`, `finish_at`) VALUES (?, ?, ?, ?, ?)',
                        { f.id, Player.PlayerData.citizenid, 'Leftover', json.encode(leftover), os.time() })
                    blocked = true
                end
                collected = true
            end
        end
    end

    if blocked then notify(src, 'inventory_full', 'error') end
    if collected then notify(src, 'collected', 'success') end
    cb(collected)
end)
