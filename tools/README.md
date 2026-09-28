# Testing co-op with one copy of the game

Two processes on one PC over 127.0.0.1. No second machine, no second license.

## Don't bother with Engine.ini

The first attempt put a net driver override in
`%LOCALAPPDATA%\SurrounDead\Saved\Config\Windows\Engine.ini`. It doesn't
survive — the game re-serializes user config from memory on exit and drops any
section it doesn't track. The block was gone by the next launch and the engine
was still on `SteamSockets.SteamSocketsNetDriver`.

Patch the live array from Lua instead. `F10` / `sdmp_ipdriver` rewrites
`GEngine.NetDriverDefinitions` in memory. Session-only, nothing on disk.

Why it's needed: SteamSockets binds a Steam P2P socket, not UDP 7777, and both
instances run as the same SteamID anyway — a P2P connection to yourself goes
nowhere. IP over loopback has neither problem.

## -log is useless here

Shipping builds compile logging out. `Saved\Logs` stays empty whatever you
pass, so engine failures are silent. Everything we learn comes from reading
engine state in Lua and `ue4ss\UE4SS.log`.

## Procedure

Host:

1. `tools\host.bat`
2. At the main menu: **F10** — want `DRV[1]: class=OnlineSubsystemUtils.IpNetDriver`
3. Console `~` → `sdmp_host`   (or `open /Game/Levels/PersistentLevel?listen`)
4. **F8** — want `driver=IpNetDriver`. If it still says `NONE (standalone)`
   the listen is failing for a different reason and we need another angle.
5. Start or load a game through the menu.
6. **F8** again — driver should still be there. If it's gone, loading a save
   travels and drops the listen state, which is its own problem.

Client:

7. `tools\second-instance.bat`
8. At its menu: **F10** (each process has its own copy of the array)
9. `~` → `open 127.0.0.1:7777`
10. **F8** — want `authority=no (we are a client)` and a pawn.
    F8 on the host should show `connections=1`.

## Keys

| Key | Command | Does |
|---|---|---|
| F7 | `sdmp_diag` | Full dump — CDOs, class chains, actor sweep |
| F8 | `sdmp_net` | One line: driver, connections, authority, pawn |
| F9 | `sdmp_drivers` | Dump `GEngine.NetDriverDefinitions` |
| F10 | `sdmp_ipdriver` | Force IP net driver for this session |
