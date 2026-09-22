# SurrounDead Multiplayer

Trying to get co-op working in [SurrounDead](https://store.steampowered.com/app/1645820/) (UE 5.3, blueprint only, no game dll).

Very early. Nothing playable yet, don't download this expecting a mod.

## What I've found so far

The dev left a surprising amount of multiplayer plumbing in. SteamSockets is already the net driver, OnlineSubsystemSteam is on, P2P relay is on. The player character has full inventory replication. What's missing is basically everything above that - no session logic, empty game mode / game state / controller. Notes in [docs/findings.md](docs/findings.md).

Current plan is UE4SS lua for the session layer and pak overrides for anything that needs blueprint changes. Haven't tested anything with two actual clients yet.

## Layout

- `mods/` - UE4SS lua mods, goes in `SurrounDead/Binaries/Win64/ue4ss/Mods/`. Right now just `SDMPDiag`, a read-only mod that dumps the net driver, roles and replicating actors to the log.
- `pak/` - asset overrides, packed into `~mods/`
- `docs/` - findings
- `research/`, `tools/` - pak extracts, repak, ue4ss archives. Not committed.
