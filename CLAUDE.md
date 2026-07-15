# CLAUDE.md — Eating Simulator (Roblox)

This file is the persistent context for Claude Code on this project. Read it before starting any session. Update it whenever a system changes — this file should always reflect the current source of truth, not the original plan.

## Project Summary

A Roblox "simulator" genre cash-grab game. Core verb: eat food to gain **Coins** (spend currency) and **Mass** (prestige/visual currency). Progress through food-tier zones, rebirth for permanent multipliers, pull gacha crates for pets/auras/titles. Priority is fast turnaround and low art/mechanic complexity — every new feature should reuse existing systems (one click-to-earn loop, one gacha system, one pet-follow script) rather than introducing new mechanics.

**Dev setup:** Claude Code is sole implementer. User is non-technical and will primarily playtest and report bugs — so error messages, console output, and explanations should assume a non-engineer reading them. Prioritize **working and stable** over clever. Flag any decision with real tradeoffs instead of silently picking one.

---

## Rojo & MCP Workflow — Read This First

This project syncs to Studio via **Rojo** and also has an **MCP connection** for direct Studio manipulation/inspection.

- **The filesystem (this repo) is the single source of truth.** `default.project.json` maps `src/` folders directly to real Roblox service locations — the file tree *is* the instance tree once synced.
- **Use MCP for live testing, debugging, and inspecting runtime state** (checking a value while a game session is running, confirming an instance exists, reading live errors) — not for permanent changes.
- **Any Studio change made via MCP that should persist must be written back into the corresponding file in `src/`.** If it only exists in the live Studio session, Rojo will overwrite it on next sync (or it'll be lost when the session ends). Treat live Studio edits as scratch/temporary until they're reflected in a file.
- When in doubt about which system owns a change, prefer editing the file and letting Rojo sync it, rather than editing Studio directly.

---

## Core Gameplay Loop

1. Player clicks/interacts with a food model (ClickDetector or ProximityPrompt)
2. Server validates the request and grants Coins + Mass
3. Coins buy zone unlocks and upgrades; Mass scales character size and feeds the leaderboard
4. At a coin threshold, player can Rebirth: reset Coins + zone progress, keep a permanent multiplier tied to Mass/Rebirth count
5. Coins/Robux buy gacha crates for cosmetic and multiplier items (pets, auras, titles)
6. Global leaderboard ranks players by Mass (or a composite score — TBD, see Open Decisions)

---

## Non-Negotiable Architecture Rules

These exist because this is a currency-driven game and will be targeted by exploiters. Do not compromise on these for speed.

- **Server-authoritative everything.** All Coin/Mass grants happen in server scripts only. The client never tells the server "give me X coins" — it says "I interacted with food instance Y," and the server looks up Y's value and grants it. Never trust a value sent from the client.
- **RemoteEvents validate on receipt.** Every RemoteEvent handler checks: is this player allowed to do this right now (debounce, zone access, cooldown)? Reject silently and log rather than trusting the payload.
- **DataStore writes are wrapped in pcall** with retry logic. Never let a failed save silently lose player data. Use `UpdateAsync`, not `SetAsync`, for anything incremented (coins, mass) to avoid overwrite races.
- **Debounce every click/prompt** server-side, not just client-side, to prevent rapid-fire exploited clicks.
- **Cache MarketplaceService gamepass checks on join**, store in the session table, don't re-query every time a gated action happens.

---

## Systems Spec

### Currencies
- **Coins** — spendable, resets on Rebirth
- **Mass** — persistent, drives character scale (visual) and leaderboard rank, also feeds Rebirth multiplier calculation

### Zones (food tiers)
Full data lives in `src/ReplicatedStorage/Modules/Config/ZoneConfig.lua` — do not hardcode these values in logic scripts, read from this module.

| Zone | Theme | Coins/bite (base) | Mass/bite (base) | Unlock cost |
|---|---|---|---|---|
| 1 | Broccoli, carrots, salad | 1 | 0.1 | Free |
| 2 | Sandwiches, rice, chicken | 5 | 0.5 | 500 coins |
| 3 | Pizza, burgers, fries | 25 | 2 | 5,000 coins |
| 4 | Cake, donuts, candy | 100 | 8 | 50,000 coins |
| 5 | Meme/absurd tier | 500 | 30 | 500,000 coins |

Values are a starting point — expect tuning after playtesting.

### Rebirth
Config lives in `src/ReplicatedStorage/Modules/Config/RebirthConfig.lua`.
- Trigger: coin threshold reached in the final unlocked zone
- Resets: Coins → 0, zone access → Zone 1 only
- Persists: Mass, cosmetics, gacha inventory
- Reward: permanent multiplier + visual tier (aura tint / badge / title unlock)

### Gacha ("Snack Crates")
Config lives in `src/ReplicatedStorage/Modules/Config/GachaConfig.lua`.
- Rarity tiers: Common / Rare / Epic / Legendary / Mythic
- Item types: Titles (build first — zero art cost), Auras (particle emitter attachments), Pets (follow-script + mesh swap, passive multiplier)
- Two crate types: free/slow (coins) and premium (Robux, better odds)
- Pity system: guaranteed Rare+ every N pulls

### Leaderboard
- `OrderedDataStore`, kept separate from the main PlayerData DataStore intentionally
- Sort key TBD (see Open Decisions)
- Client display refreshes on an interval, not per-frame, to stay under DataStore limits
- Top 100 only for MVP

### Monetization (Gamepasses)
- 2x Coins
- 2x Mass
- Auto-eat (server-side timer auto-triggers the eat action through the same validated grant path as manual clicks)
- VIP zone early access (bypass coin gate, not zone-skip exploits)

---

## DataStore Schema

Owned exclusively by `PlayerDataService.lua`.

```lua
PlayerData = {
    Coins = 0,
    Mass = 0,
    RebirthCount = 0,
    UnlockedZones = {1},
    OwnedPets = {},
    EquippedPet = nil,
    OwnedAuras = {},
    EquippedAura = nil,
    OwnedTitles = {},
    EquippedTitle = nil,
    GamepassCache = {}, -- {[passId] = bool}, populated on join
}
```

---

## Project Structure

Mirrors `default.project.json` — every folder below maps to a real location in the Roblox instance tree once Rojo syncs.

```
src/
  ServerScriptService/
    Init.server.lua            -- boot sequence, requires + starts every Service
    Services/
      PlayerDataService.lua   -- owns the PlayerProfile cache, leaderstats, and DataStore persistence
      EconomyService.lua      -- owns all Coin/Mass grants
      FoodService.lua         -- food pickup (ProximityPrompt) + eat (Tool.Activated) wiring
      ZoneAccessService.lua   -- per-player CollisionGroup zone walls + unlock-gate purchase flow
      MassVisualService.lua   -- Mass-driven R15 BodyWidthScale/BodyDepthScale visual scaling
      GachaService.lua        -- crate pulls, pity, inventory grants
      RebirthService.lua      -- rebirth eligibility + reset + multiplier
      LeaderboardService.lua  -- OrderedDataStore leaderboard
    RemoteHandlers/            -- server-side listeners for client RemoteEvents
  ReplicatedStorage/
    Modules/
      Config/
        ZoneConfig.lua
        GachaConfig.lua
        RebirthConfig.lua
        GameplayConfig.lua    -- non-zone-specific tunables (e.g. EAT_COOLDOWN_SEC)
        MassVisualConfig.lua  -- Mass -> body-scale mapping tunables (min/max scale, cap, tween time)
    Assets/
      FoodTools/               -- Tool templates, git-tracked as Rojo .model.json (e.g. Broccoli.model.json)
    Remotes/                   -- RemoteEvent/RemoteFunction instances
  Workspace/
    FoodTables/                -- placeholder food table Parts, git-tracked as Rojo .model.json
    ZoneGates/                  -- per-zone unlock wall/gate Models, git-tracked as Rojo .model.json
  StarterPlayer/
    StarterPlayerScripts/
      Init.client.lua          -- boot sequence, requires + starts every client Controller
      Controllers/
        CurrencyHUDController.lua -- top-right Coins/Mass HUD, reads leaderstats directly
```

**Naming:** PascalCase for scripts/modules, camelCase for variables/functions, ALL_CAPS for constants in config modules.

**Rule:** no script outside `PlayerDataService` touches DataStore directly. No script outside `EconomyService` mutates Coins/Mass directly. New features extend existing services/config tables rather than creating parallel systems.

---

## Build Order

Build and test each phase before moving to the next. Don't let scope creep into later phases early.

1. Leaderstats + single food click-to-eat loop (prove core loop works end to end)
2. PlayerDataService: DataStore save/load using the schema above
3. Full Zone 1 loop: eat → coins → unlock Zone 2
4. Remaining zones (asset/config swap only, no new mechanics)
5. Rebirth logic
6. Gacha: Titles only first (no art dependency, fastest to validate the system)
7. Gacha: Pets, then Auras
8. Gamepasses (bolt on last, once core loop is confirmed fun)
9. OrderedDataStore global leaderboard

---

## Open Decisions (flag these back to user, don't assume)

- Exact leaderboard sort key: pure Mass, or a composite score factoring Rebirths?
- Rebirth multiplier formula (flat % per rebirth vs. curve)? Placeholder in `RebirthConfig.lua` is flat +10%/rebirth.
- Whether Mass visually caps character scale at some max (to avoid absurd/broken proportions) or scales indefinitely
- Whether auto-eat gamepass has a cooldown floor to prevent it from trivializing manual play entirely

---

## What NOT to do

- Don't add new mechanics per zone (pathfinding, combat, puzzles) — zones are asset/number swaps only
- Don't trust any client-sent numeric value for currency grants
- Don't build multiple gacha systems for different item types — one system, swap the item table
- Don't make permanent changes via MCP/live Studio edits without writing them back to a file
- Don't optimize prematurely — get the loop fun and stable first, tune numbers after
