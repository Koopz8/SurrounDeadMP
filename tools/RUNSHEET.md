# Loopback test run sheet

Two instances on one PC over 127.0.0.1. `~` opens the console.
Everything is session-only — a relaunch resets all of it.

## Bring up the session

| # | Where | Do |
|---|---|---|
| 1 | Explorer | `tools\host.bat` |
| 2 | host menu, `~` | `sdmp_ipdriver` |
| 3 | host menu, `~` | `sdmp_host` |
| 4 | host | **F8** — want `driver=IpNetDriver` |
| 5 | host menu | Continue / Load — start the game normally |
| 6 | Explorer | `tools\second-instance.bat` |
| 7 | client menu, `~` | `sdmp_ipdriver` |
| 8 | client menu, `~` | `open 127.0.0.1:7777` |

## Get player 2 playable

| # | Where | Do |
|---|---|---|
| 9 | **host**, `~` | `sdmp_hostspawn2` |
| 10 | client | click **Continue** if the menu is still up |
| 11 | **client**, `~` | `sdmp_input2` |
| 12 | **client**, `~` | `sdmp_ui` |
| 13 | **host**, `~` | `sdmp_netperf` |

That's the full working state: two players, moving, looting, HUD up.

## Current investigation — position divergence

| # | Where | Do |
|---|---|---|
| 14 | client | run in a straight line and keep running |
| 15 | **client**, `~` | `sdmp_pos` |
| 16 | **host**, `~` | `sdmp_pos` |
| 17 | **host**, `~` | `sdmp_tick120`, then move the client again |

Steps 15 and 16 want to be within a second of each other. If the two sides
disagree by hundreds of units, that explains both the choppy movement and the
zombies chasing without ever attacking — the AI is walking to where the server
thinks you are.

## Keys and commands

| Key | Command | Does |
|---|---|---|
| F7 | `sdmp_diag` | Full dump — CDOs, class chains, actor sweep |
| F8 | `sdmp_net` | Driver, connections, authority, pawn, role |
| F9 | `sdmp_drivers` | Dump `GEngine.NetDriverDefinitions` |
| — | `sdmp_ipdriver` | Force IP net driver (F10 is taken by the console) |
| — | `sdmp_host` | Travel to PersistentLevel as a listen server |
| — | `sdmp_hostspawn2` | Host: set DefaultPawnClass, `ServerRestartPlayer` |
| — | `sdmp_input2` | Client: input mode + `IMC_General` |
| — | `sdmp_ui` | Client: `Client_AddUI` and the update RPCs |
| — | `sdmp_netperf` | Host: report and raise net driver throttles |
| — | `sdmp_pos` | Either side: pawn positions and speed |
| — | `sdmp_tick60` / `sdmp_tick120` | Host: set `NetServerMaxTickRate` |
| — | `sdmp_funcs` | List controller UFunctions |
| — | `sdmp_pawnfuncs` | List pawn UI/setup functions and components |
| — | `sdmp_ping` | Real ping via `GetPingInMilliseconds` |
| — | `sdmp_move` | Movement replication settings |

## Notes

- `sdmp_ipdriver` in **both** instances — each process has its own copy.
- `-log` produces nothing; shipping builds compile logging out. Everything
  goes to `ue4ss\UE4SS.log`, shared by both instances.
