# rsg-factory — Documentation

## Contents
1. [Architecture](#architecture)
2. [Data formats](#data-formats)
3. [Callbacks and events](#callbacks-and-events)
4. [Exports](#exports)
5. [Persistence](#persistence)
6. [Security model](#security-model)
7. [Database schema](#database-schema)
8. [Server owner how-tos](#server-owner-how-tos)
9. [Troubleshooting](#troubleshooting)

## Architecture
| File | Purpose |
|---|---|
| `fxmanifest.lua` | Resource manifest; depends on `rsg-core`, `rsg-inventory`, `rsg-target`, `oxmysql` |
| `shared/config.lua` | All settings (see README) |
| `server/server.lua` | Database build, factory cache, `/createfactory`, all callbacks and validation |
| `client/client.lua` | NPC spawning, `rsg-target` options, NUI bridge, push-to-talk whitelist |
| `html/index.html`, `style.css`, `script.js` | NUI (house "leather & gold" style, custom HTML dropdowns) |
| `locales/*.json` | 10 languages, loaded by rsg-core (`@rsg-core/shared/locale.lua`) |
| `install.sql` | Manual schema (identical to the auto-build) |
| `example_factory.lua` | Reference example (chained cigarette factory); not loaded |

Flow: admin runs `/createfactory` → server inserts the row using the admin's server-side position → all clients get the new list → editor opens. Players use the NPC → server returns the factory, its lines and the player's queue → NUI sends `start` / `collect` → the server validates and applies.

## Data formats
Production line (a factory holds up to `Config.MaxRecipes`):
```lua
{
    label   = 'Planks',                                   -- 1-48 chars
    time    = 30,                                         -- seconds per batch
    job     = nil,                                        -- optional job name
    next    = nil,                                        -- optional index of the line to run after this one (chain)
    inputs  = { { item = 'resource_wood', amount = 4 } }, -- distinct items, up to MaxItemsPerRecipe
    outputs = { { item = 'plank', amount = 2 } },
}
```
Every `item` must exist in `RSGCore.Shared.Items`. Production time for a run is `time * batches`; inputs and outputs are multiplied by `batches`.

### Chained lines
Setting `next` on a line links it to another line of the same factory. The whole run is planned on the server when the player presses *Produce* (`buildPlan`):
- Stage 1 runs the chosen batches. Each later stage runs `floor(available / needed)` batches, limited by the items the previous stage made (minimum 1, otherwise the start is refused).
- Inputs a later stage needs that the previous stage does not produce are taken from the player at the start, together with stage 1's inputs.
- Surplus and by-products are added to the final products. The player collects only the final result.
- Rules checked on save: `next` exists and is not the line itself, the line outputs at least one item the next line uses, no loops, chain length ≤ `Config.MaxChainLength`. Job locks of every stage are checked at the start.

## Callbacks and events
All use the rsg-core callback system (`RSGCore.Functions.AwaitCallback` on the client).

| Name | Args | Returns | Notes |
|---|---|---|---|
| `rsg-factory:server:getFactories` | – | `{ factories, isAdmin }` or `nil` while loading | Public list for NPC spawning |
| `rsg-factory:server:getFactory` | `factoryId` | factory state or `nil` | Distance checked |
| `rsg-factory:server:getItems` | – | `{ {name,label}... }` or `nil` | Admin only |
| `rsg-factory:server:saveFactory` | `factoryId, data` | `bool` | Admin; `data = { name, ped_model, recipes }` |
| `rsg-factory:server:deleteFactory` | `factoryId` | `bool` | Admin; removes running productions |
| `rsg-factory:server:startProduction` | `factoryId, recipeIndex, batches` | `bool` | Takes inputs, queues output |
| `rsg-factory:server:collect` | `factoryId` | `bool` | Pays out every finished production |

Events: `rsg-factory:client:sync` (server → all, public factory list) and `rsg-factory:client:openAdmin` (server → admin, opens the editor).

## Exports
None.

## Persistence
Factories and their lines live in `rsg_factories`. Running productions live in `rsg_factory_queue` with an absolute `finish_at` (unix seconds), so they continue while players are offline and across restarts. A run is one queue row whose `finish_at` is the end of the last stage; `stages` only drives the "Stage 2/3" display. Databases created by v1.0.0 get the `stages` column added automatically. The queue stores the final outputs at start time, so editing a line later does not change productions already running.

## Security model
- Factory position is taken from the admin's server-side ped, never from the client.
- Every NUI callback is re-validated on the server: permission (`Config.AdminPermission`), distance to the factory, factory/line existence, batch limits, job lock, queue limit.
- Items and amounts are sanitised on save (existing item, no duplicates, `1..MaxAmount`, time `MinTime..MaxTime`, bounded text lengths); the client never supplies prices or output amounts at production time.
- Inputs are verified with `HasItem` and removed with rollback on failure. Outputs are paid after `CanAddItem` checks; the queue row is deleted first so it can never pay twice, and anything that fails to add is re-queued as a ready leftover.
- SQL uses `?` parameters only.

## Database schema
`rsg_factories` (`id`, `name`, `ped_model`, `x`, `y`, `z`, `h`, `recipes` JSON, `created_by`) and `rsg_factory_queue` (`id`, `factory_id`, `citizenid`, `label`, `outputs` JSON, `finish_at`, `stages` JSON for chained runs). See `install.sql`. With `Config.AutoDatabase = true` they are created with `CREATE TABLE IF NOT EXISTS` on start; set it to `false` to import `install.sql` yourself.

## Server owner how-tos
- **Create a factory:** stand where the NPC should be, face the direction it should face, run `/createfactory Sawmill`.
- **Add a line:** target the NPC → *Manage Factory* → *Add Production Line*, pick items from the dropdowns, set amounts and time, *Save*.
- **Lock a line to a job:** type the job name in *Job Lock*; players need it as their active or a held multi-job job.
- **Chain lines:** in a line's editor choose *Then run (chain)* and pick the next line. Make sure the first line outputs something the next line uses.
- **Move a factory:** delete it and create a new one (placement is by admin position).
- **Change language:** `setr rsg:locale de`.
- **Example factory:** `example_factory.lua` documents a chained Cigarette Factory (`tobacco_leaf` -> `tobacco_leaf_dried` -> `cigarette` -> `cigarettes`) with item definitions for `shared/items.lua` plus in-game and SQL install steps. It is reference only and is not loaded by the manifest.

## Troubleshooting
| Problem | Fix |
|---|---|
| NPC does not appear | Check the model name in the editor / `Config.DefaultPedModel`; stand within `SpawnDistance` |
| "Manage Factory" missing | Your account needs `Config.AdminPermission`; reconnect after changing permissions |
| Console: database setup failed | Check oxmysql, or set `Config.AutoDatabase = false` and import `install.sql` |
| Item missing from the picker | It must exist in `RSGCore.Shared.Items` |
| Can't hear/talk with UI open | Keep `Config.AllowPushToTalkWhileOpen = true` |
| "Not enough product to feed the next line" | Increase batches, or raise the first line's output amount |
| Chain won't save | The linked line must use an item the previous line outputs; no loops |
| Collect says inventory full | Free space; unpaid items stay queued |

Support: https://rexshack.tebex.store
