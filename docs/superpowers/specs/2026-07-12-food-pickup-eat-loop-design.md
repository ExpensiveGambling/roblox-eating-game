# Food Pickup → Hotbar → Eat Loop — Design Spec

Date: 2026-07-12
Status: Approved for planning

## Purpose

Build the core gameplay loop end-to-end for the first time in this project: a player walks up to a
food table, picks up a food item (which becomes a Roblox Tool in their hotbar), equips it, and clicks
to eat it repeatedly, gaining Coins and Mass on each eat. This proves the loop works before it's
extended to more zones/food types (per `CLAUDE.md`'s Build Order, this is Phase 1 plus the leaderstats
half of Phase 1/2).

Scope for this pass: **Zone 1 only, one food item (Broccoli)**. The system must generalize to "one
food per zone" for Zones 2-5 later via config/asset additions only — no new mechanics or scripts.

## Out of Scope (explicitly deferred)

- Multiple food types per zone.
- Zone-unlock gating (`PlayerProfile.UnlockedZones` check) — only one zone/table exists to test right
  now; this is Phase 3 per the build order. The schema field already exists so this slots in later
  without a reshape.
- Real DataStore persistence — Coins/Mass are in-memory only this pass (see `PlayerDataService`
  section). This is intentionally deferred to its own phase per the user's build order.
- Eating animation — no animation asset exists yet. The eat cooldown (see below) is sized to match
  where an animation would eventually play, but no animation is loaded/played yet.
- Gamepass multipliers (2x Coins/Mass) — Phase 8 in the build order.

## Architecture

New/changed files:

- `src/ServerScriptService/Services/FoodService.lua` — **new**. Owns pickup interaction and eat-click
  wiring. Central, config/attribute-driven (Approach A from brainstorming) rather than per-instance
  embedded scripts, so adding Zones 2-5 later requires no new code — just a new table, a new Tool
  template, and the zone's existing `ZoneConfig` entry.
- `src/ServerScriptService/Services/EconomyService.lua` — **implemented**. Sole owner of Coin/Mass
  grants, per `CLAUDE.md`'s non-negotiable rule.
- `src/ServerScriptService/Services/PlayerDataService.lua` — **implemented**. In-memory session cache
  + leaderstats, structured so real DataStore logic can be added later without changing any calling
  code in `EconomyService` or elsewhere.
- `src/ReplicatedStorage/Modules/Config/GameplayConfig.lua` — **new**. Holds non-zone-specific
  tunables, starting with `EAT_COOLDOWN_SEC`.
- `src/Workspace/FoodTables/Zone1Table.model.json` — **new**. Rojo JSON-model placeholder table with
  a `ProximityPrompt` child and a `ZoneId` attribute.
- `src/ReplicatedStorage/Assets/FoodTools/Broccoli.model.json` — **new**. Rojo JSON-model placeholder
  `Tool` with a `Handle` Part, tagged with a `ZoneId` attribute.
- `default.project.json` — **updated** to add a `Workspace` → `src/Workspace` mapping (currently
  absent).
- `CLAUDE.md` (this project's) — **updated** after implementation to reflect `FoodService` and
  `GameplayConfig.lua` as part of the real project structure (this doc is the source of truth during
  design; `CLAUDE.md` must be kept current afterward per its own instructions).

## Data Flow

1. Player walks up to the Zone 1 table. A `ProximityPrompt` (parent Part has attribute `ZoneId = 1`)
   appears — this was a deliberate choice over a `ClickDetector` for discoverability.
2. Player triggers the prompt → Roblox fires `ProximityPromptService.PromptTriggered`
   **server-side natively** (no custom RemoteEvent required for this signal).
3. `FoodService` reads the `ZoneId` attribute off the prompt's parent. If absent, the prompt is
   ignored (safe to leave the global listener connected as non-food prompts are added later).
4. `FoodService.GivePlayerFood(player, zoneId)`:
   - Looks up `ZoneConfig[zoneId]`.
   - Destroys any existing food Tool found in the player's `Backpack` **or** currently equipped in
     their `Character` (server always replaces — the pickup prompt is never blocked/hidden based on
     what the player is currently holding, per explicit decision).
   - Clones the Tool template for that zone (e.g. `ReplicatedStorage.Assets.FoodTools.Broccoli`) into
     the player's `Backpack`.
   - Connects that Tool instance's `Activated` event to the eat handler.
5. Player presses `1` (or clicks the Backpack slot) to equip — built-in Roblox behavior, no code
   needed.
6. Player clicks with the Tool equipped → Roblox fires `Tool.Activated` **server-side natively**.
7. `FoodService`'s eat handler reads `ZoneId` from the **Tool's own attribute** (not a closure
   variable captured at pickup time — reading it fresh off the instance at click time is more robust
   and consistent with the table's attribute-driven pickup) and checks a per-player cooldown
   (`GameplayConfig.EAT_COOLDOWN_SEC`, keyed by `UserId`, not by Tool instance — deliberate, so
   swapping tools can't be used to bypass the cooldown). If the cooldown hasn't elapsed, the click is
   silently ignored.
8. If accepted: `EconomyService.GrantEatReward(player, zoneId)` reads
   `ZoneConfig[zoneId].CoinsPerBite` / `.MassPerBite` and calls `PlayerDataService.AddCoins` /
   `.AddMass`.
9. `PlayerDataService` updates its in-memory profile (`Cache[UserId]`) and mirrors the new totals
   into the player's `leaderstats.Coins` / `leaderstats.Mass` values, so the Roblox player list
   updates immediately.

The Tool is **never destroyed or consumed** by eating — it persists until the player picks up food
again (which replaces it) or leaves the game.

## Component Details

### `GameplayConfig.lua`
```lua
return {
    EAT_COOLDOWN_SEC = 1, -- placeholder until a real eat animation exists; retune to match its length
}
```

### `PlayerDataService.lua`
- `Cache: {[UserId] = PlayerProfile}`, in-memory only. Uses the full `PlayerProfile` schema already
  defined in this project's `CLAUDE.md` (`Coins`, `Mass`, `RebirthCount`, `UnlockedZones`, etc.) even
  though only `Coins`/`Mass` are populated meaningfully this pass, to avoid a reshape when
  persistence and other systems land.
- Public interface: `Get(player)`, `AddCoins(player, amount)`, `AddMass(player, amount)`. All
  currency-adjacent state changes elsewhere in the codebase must go through these — no other script
  reads/writes `Cache` directly.
- `PlayerAdded`: creates `Cache[UserId]` with schema defaults, creates a `leaderstats` Folder under
  the `Player` with `Coins` (`IntValue`) and `Mass` (`NumberValue` — Mass accrues fractionally, e.g.
  0.1/bite in Zone 1, so it cannot be an `IntValue`).
- `AddCoins`/`AddMass` mutate `Cache` and the matching `leaderstats` value together — leaderstats are
  purely a mirror of the profile, never an independent source of truth.
- `PlayerRemoving`: clears `Cache[UserId]`. A comment marks where a real DataStore flush call will be
  added in the persistence phase; no other file will need to change when that happens.

### `EconomyService.lua`
- `GrantEatReward(player, zoneId)` — reads `ZoneConfig[zoneId]`, calls `PlayerDataService.AddCoins`
  and `.AddMass`. No gamepass multiplier logic (out of scope, see above).

### `FoodService.lua`
- `Start()` connects one global `ProximityPromptService.PromptTriggered` listener.
- Per-player `lastEatTime: {[UserId]: number}` table for the cooldown check, cleared on
  `PlayerRemoving` to avoid a leak.
- `GivePlayerFood(player, zoneId)` as described in Data Flow step 4.

### Placeholder physical assets (git-tracked via Rojo JSON models)
Rojo's `.model.json` format allows hand-authoring simple instance trees (ClassName, properties,
children, attributes) as plain text — fully readable/diffable in git, no Studio round-trip or binary
export required. This was chosen specifically so a future Claude Code session can read exactly what
exists in the world without needing a live Studio/MCP connection, addressing the project's
multi-session continuity concern.

- `Zone1Table.model.json`: a `Part` (placeholder block) with a child `ProximityPrompt`
  (`ActionText = "Pick Up"`, `ObjectText = "Broccoli"`) and attribute `ZoneId = 1`.
- `Broccoli.model.json`: a `Tool` with a `Handle` Part (placeholder block sized/shaped roughly like a
  held item) and attribute `ZoneId = 1`.

Placeholder `CFrame`/`Size` values are hand-picked reasonable defaults, not visually tuned in the
Studio viewport. If the table or tool is later repositioned/resized visually in Studio, that change
must be copied back into the `.model.json` file to persist (same rule this project's `README.md`
already states for any live Studio edit).

## Edge Cases

- **Player leaves mid-hold:** Roblox auto-cleans their `Backpack`/`Character`; `FoodService` clears
  their `lastEatTime` entry on `PlayerRemoving`.
- **Concurrent players at the same table:** naturally safe. `PromptTriggered` passes the specific
  `player`; each gets an independent Tool clone into their own `Backpack`. No shared mutable state is
  keyed by table.
- **Rapid re-pickup spam:** harmless. Destroy-then-clone runs synchronously with no yields in between,
  so it can't race itself, and repeated pickups grant no currency — only eating does.
- **Cooldown survives tool replacement:** cooldown is tracked per-player, not per-tool, specifically
  to prevent swapping tools as a cooldown-bypass exploit.

## Testing / Verification Plan

After implementation, use the Roblox Studio MCP connection to:
1. Start Play mode.
2. Walk a test character to the Zone 1 table and trigger the prompt.
3. Confirm a Broccoli Tool appears in the Backpack/hotbar.
4. Equip slot 1, click repeatedly, and confirm the 1-second cooldown blocks spam-clicks (reward only
   granted once per second, not once per click).
5. Confirm `leaderstats.Coins` increments by exactly `ZoneConfig[1].CoinsPerBite` (1) and
   `leaderstats.Mass` by exactly `ZoneConfig[1].MassPerBite` (0.1) per accepted eat.
6. Pick up food again while already holding a Tool and confirm it's replaced, not duplicated.
7. Check the console for errors throughout.
