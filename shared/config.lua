Config = {}

-- Build the database tables automatically on start.
-- Set to false and import install.sql manually instead.
Config.AutoDatabase = true

-- Admin command + permission level needed to create / edit / delete factories
Config.CommandName = 'createfactory'
Config.AdminPermission = 'admin'

-- Factory NPC
Config.DefaultPedModel = 'a_m_m_rancher_01' -- used when an admin leaves the model empty or invalid
Config.InteractDistance = 2.5               -- target distance (server allows a little extra)
Config.SpawnDistance = 60.0                 -- NPCs spawn/despawn around this distance

-- Limits (enforced on the server)
Config.MaxRecipes = 20            -- production lines per factory
Config.MaxItemsPerRecipe = 6      -- distinct input items and distinct output items per line
Config.MaxAmount = 1000           -- max amount of one item in a line
Config.MinTime = 1                -- seconds per batch
Config.MaxTime = 3600
Config.MaxChainLength = 5        -- production lines that can be linked in one chain
Config.MaxBatches = 50            -- batches a player can start at once
Config.MaxQueuePerPlayer = 5      -- running productions per player per factory

-- While NUI is open, block game controls but allow push-to-talk.
Config.AllowPushToTalkWhileOpen = true
Config.PushToTalkControls = {
    0x4BC9DABB, -- INPUT_PUSH_TO_TALK
}
