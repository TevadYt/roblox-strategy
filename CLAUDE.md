# roblox-strategy

Server-authoritative Roblox strategy game. Code is Luau, synced into Studio with Rojo.

## Layout

- `src/server` → `ServerScriptService.Server`. `init.server.luau` loads every module in `Services/`, calls all `Init` then all `Start`.
- `src/client` → `StarterPlayer.StarterPlayerScripts.Client`.
- `src/shared` → `ReplicatedStorage.Shared`. Config and code both sides use.
- `Packages/` → `ReplicatedStorage.Packages` (Wally, git-ignored).

## Rules

- The server decides everything. The client sends requests and displays state; never trust a value the client sends (check costs, ranges, ownership, cooldowns on the server).
- Game numbers go in `src/shared/GameConfig.luau`, not inline.
- Every file starts with `--!strict`. Files use the `.luau` extension.
- A new server system is a new module in `src/server/Services` with `Init`/`Start`. `Init` must not yield.
- Server-to-client state that is per player goes in Player attributes unless it needs events; then add a RemoteEvent and validate its arguments on the server.

## Checks (CI runs these on every PR)

```
stylua --check src
selene src
rojo build -o game.rbxl
```

Tool versions are pinned in `rokit.toml`.
