# Loopback test run sheet

Every step, in order. `~` opens the console.

## Host

| # | Where | Do |
|---|---|---|
| 1 | Explorer / bash | `tools\host.bat` |
| 2 | main menu, `~` | `sdmp_ipdriver` |
| 3 | main menu, `~` | `sdmp_host` |
| 4 | | **F8** — want `driver=IpNetDriver` |
| 5 | menu | Continue / Load — start the game normally |
| 6 | | **F8** — driver should still be there |

## Client

| # | Where | Do |
|---|---|---|
| 7 | Explorer / bash | `tools\second-instance.bat` |
| 8 | main menu, `~` | `sdmp_ipdriver` |
| 9 | main menu, `~` | `open 127.0.0.1:7777` |
| 10 | | **F8** — want `authority=no (we are a client)`, `pawn=NONE` |

## Spawn player 2

| # | Where | Do |
|---|---|---|
| 11 | **host**, `~` | `sdmp_hostspawn2` |
| 12 | client | menu may still be up — click **Continue** to clear it |
| 13 | **client**, `~` | `sdmp_input` |
| 14 | | try moving |

Step 12 is a wart. Continue runs the *client's own* save-load flow, which a
joining player should never do. It hasn't broken anything yet because the
world is the host's, but suppressing the menu for clients is on the list.

## Keys

| Key | Command | Does |
|---|---|---|
| F7 | `sdmp_diag` | Full dump — CDOs, class chains, actor sweep |
| F8 | `sdmp_net` | Driver, connections, authority, pawn, role |
| F9 | `sdmp_drivers` | Dump `GEngine.NetDriverDefinitions` |
| — | `sdmp_ipdriver` | Force IP net driver (F10 is taken by the console) |
| — | `sdmp_host` | Travel to PersistentLevel as a listen server |
| — | `sdmp_hostspawn2` | Host: set DefaultPawnClass, ServerRestartPlayer |
| — | `sdmp_input` | Client: report and repair input / possession |
| — | `sdmp_funcs` | List spawn/respawn/possess UFunctions on the controller |
| — | `sdmp_spawn` | Client: try the game's own respawn RPCs (dead end, kept) |

## Notes

- `sdmp_ipdriver` in **both** instances — each process has its own copy of
  the array.
- Everything is session-only. Nothing persists; a relaunch resets it all.
- `-log` produces nothing. Shipping builds compile logging out. All output
  goes to `ue4ss\UE4SS.log`, which both instances share.
