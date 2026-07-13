# Roblox Eating Game

## Setup
1. Install Rojo (VS Code extension or CLI) and the Rojo Studio plugin if you haven't already.
2. Open this folder in your editor.
3. Run `rojo serve` from this directory.
4. In Roblox Studio, connect via the Rojo plugin to start syncing.

## Folder structure
```
src/
  ServerScriptService/
    Services/          -- one module per system (PlayerData, Economy, Gacha, Rebirth, Leaderboard)
    RemoteHandlers/     -- server-side RemoteEvent/RemoteFunction listeners
  ReplicatedStorage/
    Modules/
      Config/           -- data tables only: ZoneConfig, GachaConfig, RebirthConfig
    Remotes/             -- RemoteEvent/RemoteFunction instances
  StarterPlayer/
    StarterPlayerScripts/  -- client-side UI/controllers
```

This mirrors `default.project.json` — every folder here maps directly to a real location in the Roblox instance tree once synced.

## Workflow note (Rojo + MCP)
This project uses Rojo to sync the filesystem to Studio, and also has an MCP connection for Claude Code to directly inspect/manipulate the live Studio session.

**The filesystem is the single source of truth.** Use MCP for live testing, debugging, and inspecting instance state — not for permanent changes. Any change made directly in Studio via MCP that should persist needs to be written back into the corresponding file here, or Rojo will overwrite it on the next sync (or your file changes will overwrite the Studio edit, depending on sync direction). If Claude Code makes a live Studio change during a debugging session, treat it as temporary until it's reflected in a file.

## Files in this folder
- `CLAUDE.md` — full project spec and context for Claude Code. Read on every session.
- `default.project.json` — Rojo sync mapping.
- `src/` — actual game source, pre-scaffolded per CLAUDE.md's architecture section.
