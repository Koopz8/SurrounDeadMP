# SurrounDead Multiplayer — handoff

Last updated 2026-09-28.

Co-op for SurrounDead (Steam 1645820). Two players share a world, move, loot,
and have a working HUD. Not shippable yet — see **Open problems**.

---

## The build

| | |
|---|---|
| Engine | Unreal Engine 5.3 (`++UE5+Release-5.3-CL-29314046`) |
| Build | Monolithic Shipping, Blueprint-only, no game DLL |
| Pak | One classic `.pak`, V11, Oodle, **unencrypted index**, no IoStore |
| Steam App ID | 1645820 |
| Plugins | Jigsaw Inventory, SmartAI, EasyMultiSave, SteamCore, UltraDynamicSky, Narrative |

No IoStore and no index encryption means loose `~mods` pak overrides work with
no patching and no AES key.

## Where things live

| Path | What |
|---|---|
| `~/dev/SurrounDeadMP` | The repo |
| `mods/SDMPDiag/` | The UE4SS Lua mod. Mirrors the game's `ue4ss/Mods/` |
| `tools/` | `host.bat`, `second-instance.bat`, `RUNSHEET.md` |
| `docs/findings.md` | Full investigation log |
| `research/` | Pak extracts, replication scans, exe strings. Gitignored |
| `<game>/Binaries/Win64/ue4ss/` | UE4SS experimental build 1140 (DEV), installed |
| `<game>/Binaries/Win64/ue4ss/UE4SS.log` | **All output goes here.** Both instances share it |

Game folder: `C:\Program Files (x86)\Steam\steamapps\common\SurrounDead`

---

## What was actually wrong

"Multiplayer doesn't work" turned out to be four unrelated gaps, none of them
replication work. The game replicates fine — 4,266 of 22,583 world actors
already replicate, including every loot container, all 850 zombie spawners,
vehicles and buildables.

| Problem | Fix |
|---|---|
| Net driver is SteamSockets — can't do loopback, both instances share one SteamID | patch `GEngine.NetDriverDefinitions` to `IpNetDriver` |
| `GameMode.DefaultPawnClass` was **never set**, so a joiner had nothing to be given | set it, then call `ServerRestartPlayer` |
| Client stuck in menu input mode | `SetInputMode_GameOnly(pc, false)` — note the 2-arg form |
| `IMC_General` (Enhanced Input) never added on clients | `AddMappingContext` on the local player subsystem |
| Client had no UI at all | `Client_AddUI` on the character |

The last three are all the same shape: the game's normal start flow does this
work, and a player who arrives by *connecting* rather than by starting a game
skips that flow entirely. Expect more bugs of this shape.

`BP_SurroundeadGameMode` has no login hooks whatsoever — its only event is
`ReceiveBeginPlay`. It never spawns anyone.

The community enabler ships `tphost` / `mprespawn` / `mpfix` to paper over the
spawning problem. None of it is necessary once `DefaultPawnClass` exists.

## SteamCore is already in the binary

`SteamCore_5.3` is linked into the shipping exe — 129 symbols, including
`CreateLobby`, `JoinLobby`, `RequestLobbyList` with the full filter set,
`InviteUserToLobby`, `GameLobbyJoinRequested`, and the delegates. These are
reflected UFunctions, so **UE4SS Lua can call them directly**. That's the whole
session layer, already present. Not yet used.

---

## Running a test

No second machine or second copy needed — two processes on one PC over
127.0.0.1. `~` opens the console. Everything is session-only; a relaunch
resets all of it.

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
| 9 | **host**, `~` | `sdmp_hostspawn2` |
| 10 | client | click **Continue** if the menu is still up |
| 11 | **client**, `~` | `sdmp_input2` |
| 12 | **client**, `~` | `sdmp_ui` |
| 13 | **host**, `~` | `sdmp_netperf` |

Order matters at step 3: `open <map>?listen` reloads the map, and SurrounDead's
world isn't in the map — it's built by the load-save flow. Hosting after you've
started playing throws the world away.

`sdmp_ipdriver` goes in **both** instances; each process has its own copy of
the array.

## Commands

| Key | Command | Does |
|---|---|---|
| F7 | `sdmp_diag` | Full dump — CDOs, class chains, actor sweep |
| F8 | `sdmp_net` | Driver, connections, authority, pawn, role |
| F9 | `sdmp_drivers` | Dump `GEngine.NetDriverDefinitions` |
| — | `sdmp_ipdriver` | Force IP net driver (F10 is taken by the console) |
| — | `sdmp_host` | Travel to PersistentLevel as a listen server |
| — | `sdmp_hostspawn2` | Host: set `DefaultPawnClass`, `ServerRestartPlayer` |
| — | `sdmp_input2` | Client: input mode + `IMC_General` |
| — | `sdmp_ui` | Client: `Client_AddUI` and the update RPCs |
| — | `sdmp_netperf` | Host: report and raise net driver throttles |
| — | `sdmp_funcs` / `sdmp_pawnfuncs` / `sdmp_animfuncs` | Enumerate UFunctions |
| — | `sdmp_fine3` | Position trace with world time |
| — | `sdmp_pos` / `sdmp_track_host` / `sdmp_track_client` | Position traces |
| — | `sdmp_move` / `sdmp_ping` / `sdmp_priority` | Movement and net numbers |
| — | `sdmp_rootmotion2` | Root motion mode |
| — | `sdmp_repossess` / `sdmp_reown` | Redo the possession handshake |

Enumerating UFunctions on a class chain is what found `ServerRestartPlayer`,
`Client_AddUI` and the `Svr_RequestRespawn_*` family. It has been the single
most productive technique here — reach for it before theorising.

---

## Open problems

### 1. Client movement stutters — UNSOLVED, eight theories dead

The client's own character freezes briefly mid-run then catches up. The host is
smooth, and the host's character *seen from the client* is also smooth. Only
the client's own pawn is affected — which is backwards, since that one is
locally predicted and shouldn't care about the network at all.

Ruled out by measurement, not assumption:

| Suspect | Finding |
|---|---|
| Position divergence | Client and server agree exactly |
| Sprint speed not replicating | `MaxWalkSpeed=750` on both sides |
| Server tick rate | Was 30, raised to 60 then 120, no change |
| Bandwidth | `MaxClientRate` was already 1e9 |
| Actor priority starvation | Was `NetPriority=3`, `NetUpdateFrequency=100`; forcing 20 / always-relevant / 120 changed nothing |
| GPU / frame rate | Host 7.55 ms, client 5.77 ms — both over 130 fps |
| Dropped frames | Measured the video frame by frame: zero drops while running |
| Ownership / possession | `Owner` and `Controller` correct on both sides; forced re-possess changed nothing |
| Generic transform replication fighting prediction | `SetReplicateMovement(false)` changed nothing |
| Root motion | `AnimInstance.RootMotionMode = 3` (montages-only, net-safe), `IsPlayingRootMotion=false` |

**Important caveat on the remaining evidence.** The one measurement pointing at
a movement fault — position advancing in `0 … 31` chunks — may be an artifact
of how it was sampled. `LoopAsync` sleeps on a worker thread and queues onto the
game thread; if the game thread drains several queued callbacks in one frame,
consecutive samples read the same position and the next batch jumps. That is
exactly the pattern observed. `sdmp_fine3` records world time with each sample
to settle it: no time passing between "stalled" samples means the instrument
was measuring itself.

**Next step:** run `sdmp_fine3`. If it shows batching, the movement theories
were chasing nothing and the hunt moves to animation, camera or mesh
interpolation. If time advances while position doesn't, the stall is real.

### 2. Zombies chase the client but never attack

Untouched. Was dropped mid-investigation on a theory (position divergence) that
later proved wrong, so it has never actually been looked at. Gameplay-blocking,
and probably more tractable than the stutter — it's a damage and perception
path, not engine internals. Health never dropping is likely downstream of this
rather than a separate bug, though note `Client_UpdateHealthUI` needs a
parameter that was never passed, so the bar may also just not update.

### 3. Everything is a console command

Nothing is automatic. A real mod does all of this on possession, not by hand.
The `sdmp_*` commands are a test harness, not the product.

### 4. Other known gaps

- The client's main menu stays up until you click **Continue**, which runs the
  *client's own* save-load flow. Should be suppressed for clients.
- Players spawn at a PlayerStart, ~2.5 km from the host. Should spawn together.
- `ShowCompassWidget` and the `Client_Update*` RPCs want parameters we haven't
  worked out.
- Saves for non-host players: untouched. EasyMultiSave documents MP support but
  saves per-actor.
- ~11 interactable classes have no authority model: `BP_POIManager_C` (187),
  Laboratory lights and switches (~250), `BP_Ladder_C` (48),
  `BP_LaboratorySlidingDoor_C` (39), `BP_LockedDoor_C` (20), `BP_ZombieDoor_C`,
  `BP_ToolRequired_*`, `BP_WaterWell_C`. The Laboratory is the worst — it's
  effectively a single-player set piece.

---

## Gotchas that cost time

- **Shipping builds compile logging out.** `-log` produces nothing; `Saved\Logs`
  stays empty. Everything must come through `UE4SS.log`.
- **UE 5.3 changed arities.** `BeginDeferredActorSpawnFromClass` takes 6 args
  (added `TransformScaleMethod`), `SetInputMode_GameOnly` takes 2. Silent
  failures otherwise — `pcall` everything and log the result.
- **Enum properties come back as wrappers,** not numbers. Unwrap with `get()`
  before believing a value.
- **`LoopAsync` + `ExecuteInGameThread` can batch onto one frame.** Don't use it
  for timing-sensitive traces without recording world time.
- **Clients have no PlayerController for other players.** Anything iterating
  controllers can never see a remote character; enumerate `Character` instead.
- **The user config `Engine.ini` does not survive.** The game re-serializes it
  on exit and drops sections it doesn't track. Patch live objects instead.
- **Git leaves lock files** in this repo because the folder mount can't delete.
  After a Claude-side commit: `rm -f .git/HEAD.lock .git/objects/maintenance.lock`
  and `find .git/objects -name 'tmp_obj_*' -delete`.
