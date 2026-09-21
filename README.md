# SurrounDead Multiplayer

Co-op for SurrounDead (Steam 1645820, Unreal Engine 5.3).

## Layout

| Path | What |
|---|---|
| `mods/` | UE4SS Lua mods. Mirrors `SurrounDead/Binaries/Win64/ue4ss/Mods/` |
| `pak/` | Cooked asset overrides, packed into `~mods/` |
| `research/` | Pak extracts and replication scans. Not committed |
| `tools/` | repak, UE4SS archives. Not committed |
| `docs/` | Findings and design notes |

## State

Recon done. UE4SS (experimental 1140, DEV) installed into the game with
`SDMPDiag` enabled. Nothing has been tested in a live session yet.

The game already ships with SteamSockets as its net driver, Steam P2P relay
on, and `OnlineSubsystemSteam` enabled — see `docs/findings.md`. The missing
pieces are the session layer, the game mode, and world-state authority.
