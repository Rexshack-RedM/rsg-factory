# rsg-factory

**Version 1.1.0** · Requires: `rsg-core`, `rsg-inventory`, `rsg-target`, `oxmysql`

Admin-built factories for the RSG Framework. An admin stands where the factory NPC should be, runs `/createfactory`, and then defines production lines in an NUI: which items go in, which items come out, and how long it takes. Players use the NPC to start production, wait, and collect.

See [DOCS.md](DOCS.md) for the full developer and server-owner documentation.

## Features
- `/createfactory [name]` places a factory NPC at the admin's position and opens the editor
- Admin editor: factory name, NPC model, any number of production lines
- Each line has multiple input items, multiple output items, time per batch and an optional job lock
- Searchable item picker built from your server's items (no manual typing of item names)
- **Chained lines:** link a line to another ("Then run") so when it finishes the next one starts automatically; the first line's products feed the next line
- Players pick a line and a batch count; inputs are taken and production runs in real time
- Production keeps running while the player is offline and survives restarts; collect any time at the NPC
- NPCs spawn only when a player is nearby; interaction through `rsg-target`
- Push-to-talk keeps working while the UI is open
- Locales: en, de, el, es, fr, ja, nl, pl, pt-br, ro

## Installation
1. Put `rsg-factory` in your resources folder.
2. Add `ensure rsg-factory` to your `server.cfg` after `rsg-core`, `rsg-inventory`, `rsg-target` and `oxmysql`.
3. Database: tables are created automatically on first start. To install manually, set `Config.AutoDatabase = false` in `shared/config.lua` and import `install.sql`.
4. Set your language with `setr rsg:locale en` (or any supported language).

## Usage
| Command | Permission | Description |
|---|---|---|
| `/createfactory [name]` | `Config.AdminPermission` (default `admin`) | Creates a factory at your position and opens the editor |

- **Admins:** target the NPC and choose *Manage Factory* to edit lines, rename, change the NPC model or delete the factory.
- **Players:** target the NPC and choose *Use Factory*, pick a production line, set the batches and press *Produce*. Press *Collect* once the timer shows *Ready*.

## Configuration
| Option | Default | Description |
|---|---|---|
| `AutoDatabase` | `true` | Create tables automatically (set `false` to import `install.sql`) |
| `CommandName` | `'createfactory'` | Admin command name |
| `AdminPermission` | `'admin'` | Permission needed to create/edit/delete factories |
| `DefaultPedModel` | `'a_m_m_rancher_01'` | NPC model used when none or an invalid one is set |
| `InteractDistance` | `2.5` | Target distance |
| `SpawnDistance` | `60.0` | NPC spawn/despawn distance |
| `MaxRecipes` | `20` | Production lines per factory |
| `MaxItemsPerRecipe` | `6` | Distinct inputs and distinct outputs per line |
| `MaxAmount` | `1000` | Max amount of one item in a line |
| `MinTime` / `MaxTime` | `1` / `3600` | Allowed seconds per batch |
| `MaxChainLength` | `5` | Lines that can be linked in one chain |
| `MaxBatches` | `50` | Batches per production start |
| `MaxQueuePerPlayer` | `5` | Running productions per player per factory |
| `AllowPushToTalkWhileOpen` | `true` | Allow push-to-talk while the UI is open |
| `PushToTalkControls` | `{ 0x4BC9DABB }` | Controls kept active while the UI is open |

## Example factory
`example_factory.lua` is a reference-only file (not loaded by the resource) with a three-stage chained Cigarette Factory: dry tobacco, cut and roll, pack. It contains the production lines, step-by-step instructions for building it in the editor, item definitions for `shared/items.lua`, and a ready-made SQL insert. Make sure the items it uses exist on your server first.

## Notes
- The default NPC model could not be checked against the RedM brain while writing this; if it does not spawn on your build, change the model in the editor or `Config.DefaultPedModel`.
- Chains: a linked line must make at least one item the next line uses, and loops are not allowed. The next line runs as many batches as the previous line's output can feed (so batches may need to be higher if a line makes less than the next one needs). Inputs the next line needs that the previous line doesn't make are taken at the start, and surplus or by-products are paid out with the final products.
- Deleting a factory also deletes productions still running there.

Support: https://rexshack.tebex.store
