local RSGCore = exports['rsg-core']:GetCoreObject()

local factories = {} -- [id] = { id, name, ped_model, x, y, z, h }
local spawned = {}   -- [id] = ped
local isAdmin = false
local uiOpen, uiFocus = false, false
local currentId = nil

local UI_KEYS = {
    'ui_recipes', 'ui_inputs', 'ui_outputs', 'ui_time', 'ui_batches', 'ui_produce', 'ui_queue',
    'ui_collect', 'ui_ready', 'ui_no_recipes', 'ui_no_queue', 'ui_close', 'ui_admin_title',
    'ui_factory_name', 'ui_ped_model', 'ui_add_recipe', 'ui_recipe_name', 'ui_seconds',
    'ui_job_lock', 'ui_add_item', 'ui_save', 'ui_delete', 'ui_confirm_delete', 'ui_remove',
    'ui_search_item', 'ui_amount', 'ui_cancel', 'ui_confirm', 'ui_seconds_short', 'ui_next_line', 'ui_no_next', 'ui_stage',
}

---------------------------------------------------------------------
-- NUI focus (keeps push-to-talk working)
---------------------------------------------------------------------
local function applyNuiFocus(enable)
    if enable then
        SetNuiFocus(true, true)
        if Config.AllowPushToTalkWhileOpen then
            SetNuiFocusKeepInput(true)
        end
    else
        SetNuiFocusKeepInput(false)
        SetNuiFocus(false, false)
    end
end

local function runPttWhitelist()
    DisableAllControlActions(0)
    DisableAllControlActions(1)
    DisableAllControlActions(2)
    local list = Config.PushToTalkControls
    if list then
        for i = 1, #list do
            local c = list[i]
            EnableControlAction(0, c, true)
            EnableControlAction(1, c, true)
            EnableControlAction(2, c, true)
        end
    end
end

CreateThread(function()
    while true do
        if uiFocus and Config.AllowPushToTalkWhileOpen then
            Wait(0)
            runPttWhitelist()
        else
            Wait(250)
        end
    end
end)

local function closeUi()
    if not uiOpen then return end
    uiOpen = false
    uiFocus = false
    currentId = nil
    applyNuiFocus(false)
    SendNUIMessage({ action = 'close' })
end

local function strings()
    local t = {}
    for i = 1, #UI_KEYS do t[UI_KEYS[i]] = locale(UI_KEYS[i]) end
    return t
end

---------------------------------------------------------------------
-- Opening the UI
---------------------------------------------------------------------
local function fetchFactory(id)
    return RSGCore.Functions.AwaitCallback('rsg-factory:server:getFactory', 10000, id)
end

local function openUi(id, mode)
    if uiOpen then return end
    local data = fetchFactory(id)
    if not data then return end

    local items = nil
    if mode == 'admin' then
        if not data.isAdmin then return end
        items = RSGCore.Functions.AwaitCallback('rsg-factory:server:getItems', 10000)
        if not items then return end
    end

    currentId = id
    uiOpen = true
    uiFocus = true
    SendNUIMessage({ action = 'open', mode = mode, factory = data, items = items, strings = strings() })
    applyNuiFocus(true)
end

RegisterNetEvent('rsg-factory:client:openAdmin', function(id)
    CreateThread(function() openUi(id, 'admin') end)
end)

---------------------------------------------------------------------
-- NUI callbacks (all re-validated on the server)
---------------------------------------------------------------------
RegisterNUICallback('close', function(_, cb)
    closeUi()
    cb(true)
end)

RegisterNUICallback('refresh', function(_, cb)
    if not currentId then return cb(false) end
    cb(fetchFactory(currentId) or false)
end)

RegisterNUICallback('start', function(data, cb)
    if not currentId or type(data) ~= 'table' then return cb(false) end
    local ok = RSGCore.Functions.AwaitCallback('rsg-factory:server:startProduction', 10000, currentId, data.recipe, data.batches)
    cb(ok and true or false)
end)

RegisterNUICallback('collect', function(_, cb)
    if not currentId then return cb(false) end
    local ok = RSGCore.Functions.AwaitCallback('rsg-factory:server:collect', 10000, currentId)
    cb(ok and true or false)
end)

RegisterNUICallback('save', function(data, cb)
    if not currentId or type(data) ~= 'table' then return cb(false) end
    local ok = RSGCore.Functions.AwaitCallback('rsg-factory:server:saveFactory', 10000, currentId, data)
    cb(ok and true or false)
end)

RegisterNUICallback('delete', function(_, cb)
    if not currentId then return cb(false) end
    local ok = RSGCore.Functions.AwaitCallback('rsg-factory:server:deleteFactory', 10000, currentId)
    cb(ok and true or false)
end)

---------------------------------------------------------------------
-- Factory NPCs (spawned only when the player is near)
---------------------------------------------------------------------
local function loadModel(hash)
    if not IsModelValid(hash) then return false end
    RequestModel(hash)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > timeout then return false end
        Wait(50)
    end
    return true
end

local function removeFactoryPed(id)
    local ped = spawned[id]
    if not ped then return end
    exports['rsg-target']:removeLocalEntity(ped)
    if DoesEntityExist(ped) then DeleteEntity(ped) end
    spawned[id] = nil
end

local function spawnFactoryPed(f)
    local hash = GetHashKey(f.ped_model)
    if not loadModel(hash) then
        hash = GetHashKey(Config.DefaultPedModel)
        if not loadModel(hash) then return end
    end

    local ped = CreatePed(hash, f.x, f.y, f.z, f.h, false, false, false, false)
    if not ped or ped == 0 then return end

    Citizen.InvokeNative(0x283978A15512B2FE, ped, true) -- SetRandomOutfitVariation
    SetEntityAsMissionEntity(ped, true, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    PlaceEntityOnGroundProperly(ped, true)
    SetEntityHeading(ped, f.h)
    FreezeEntityPosition(ped, true)
    SetModelAsNoLongerNeeded(hash)

    local id = f.id
    exports['rsg-target']:addLocalEntity(ped, {
        {
            name = 'rsg_factory_use',
            icon = 'fa-solid fa-industry',
            label = locale('target_use'),
            distance = Config.InteractDistance,
            onSelect = function() CreateThread(function() openUi(id, 'player') end) end,
        },
        {
            name = 'rsg_factory_manage',
            icon = 'fa-solid fa-gear',
            label = locale('target_manage'),
            distance = Config.InteractDistance,
            canInteract = function() return isAdmin end,
            onSelect = function() CreateThread(function() openUi(id, 'admin') end) end,
        },
    })
    spawned[id] = ped
end

CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        for id, f in pairs(factories) do
            local dist = #(pos - vector3(f.x, f.y, f.z))
            if dist < Config.SpawnDistance and not spawned[id] then
                spawnFactoryPed(f)
            elseif dist > Config.SpawnDistance + 10.0 and spawned[id] then
                removeFactoryPed(id)
            end
        end
        Wait(1000)
    end
end)

local function applyFactories(list)
    for id in pairs(spawned) do removeFactoryPed(id) end
    factories = {}
    for i = 1, #list do factories[list[i].id] = list[i] end
end

RegisterNetEvent('rsg-factory:client:sync', function(list)
    applyFactories(list or {})
    if uiOpen and currentId and not factories[currentId] then closeUi() end
end)

local function loadFactories()
    local res
    for _ = 1, 60 do
        res = RSGCore.Functions.AwaitCallback('rsg-factory:server:getFactories', 10000)
        if res then break end
        Wait(1000) -- server still loading
    end
    if not res then return end
    isAdmin = res.isAdmin
    applyFactories(res.factories)
end

CreateThread(loadFactories)

RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    CreateThread(loadFactories)
end)

---------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if uiFocus then applyNuiFocus(false) end
    for id in pairs(spawned) do removeFactoryPed(id) end
end)
