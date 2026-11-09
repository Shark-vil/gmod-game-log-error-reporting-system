# GLRS - GameLog Error Reporting System

A bridge between players and addon creators. One command collects everything a creator needs to diagnose a problem and saves it as a text file the player can send.

## Usage

| Method | Command |
|---|---|
| Console | `glrs_report` |
| Chat | `!glrs` (the message is hidden from other players) |

The command starts a **25 second test**, so play normally while it runs. Progress messages appear in chat. When it finishes, the report is saved to:

```
garrysmod/data/glrs_reports/client_YYYYMMDD_HHMMSS.txt
garrysmod/data/glrs_reports/server_YYYYMMDD_HHMMSS.txt
```

- **Client report:** any player.
- **Server report:** admins only (or anyone in singleplayer). It stays on the server. The server console (rcon) can also run `glrs_report`.
- Reports are never deleted automatically. Delete them from the folder yourself if you want.

## What a report contains

Each report starts with `PROBLEMS DETECTED`, an automatic summary, followed by the details:

- **Game and environment:** GMod version and branch, LuaJIT, map, gamemode, player count, relevant ConVars, resolution and DX level.
- **Addons:** workshop subscriptions with mounted/downloaded state, mounted games (CSS, HL2, etc.), local `addons/` folders.
- **Players:** team, health, active weapon, full weapon list, ping, model. No names, SteamIDs or IPs.
- **Entities:** counts per class, spawned (non-map) entities with model, position, health and owner (via CPPI when a prop protection addon provides it), edict usage.
- **Models:** every model used by entities, checked with `util.IsValidModel` and `file.Exists` on the side that made the report. Missing models are listed as errors.
- **Lua environment:** Lua memory, scripted entity/weapon/concommand counts, hook events with the most handlers.
- **Lua errors:** deduplicated, with count, first/last time, addon and stack. Errors that occurred during the test are marked.
- **25 s test:** FPS (client) or Think rate (server) with average, 1% low and spikes over 100 ms; Lua memory and entity count before and after; Lua CPU profile (top files and functions); time spent per `hook.Call` event.

## How it works

- **Error buffer:** errors are kept in RAM only, via the `OnLuaError` hook. Identical errors are merged into one entry with a counter, and the buffer holds at most 200 distinct entries (oldest are evicted), so memory stays bounded. Nothing is written to disk until a report is made.
- **Profiler:** a sampling profiler (`debug.sethook` count hook, one sample per 1000 Lua VM instructions). It is lighter than a call/return profiler and distorts the game less. JIT is turned off during the test (JIT-compiled code does not trigger debug hooks) and restored afterwards.

## Limitations

- The profiler counts Lua VM instructions, not wall-clock time. Time spent in engine code (rendering, physics, traces) is **not** attributed to the calling script. Use the per-hook timing table as a hint for those cases.
- `hook.Call` timing is per event, not per addon, and nested hooks are counted twice.
- File paths of workshop addons do not contain the addon name, so the profile is grouped by file, not by addon.
- Errors that happened before this addon loaded are not captured.
- `OnLuaError` may not fire on the server in every GMod branch. In that case the server report has no error section content, but everything else works.
- A client sees weapons and entities of other players only when they are networked to it.

## Installation

Put the folder into `garrysmod/addons/`. For the server report, install it on the server as well.

## Privacy

Reports contain no player names, SteamIDs or IP addresses. They do include installed and subscribed addons, the map, and server hostname (server report). Review a report before sending it if this matters to you.
