# What's in the build

Recon 2026-09-21, against the installed Steam build.

- **Unreal Engine 5.3** (`++UE5+Release-5.3-CL-29314046`), monolithic Shipping,
  Blueprint-only — no game DLL.
- One classic `.pak`, **V11, Oodle, unencrypted index**. No IoStore, no
  `.utoc`/`.ucas`. Loose `~mods` pak overrides will work with no patching.
- Marketplace plugins in use: Jigsaw Inventory, SmartAI, EasyMultiSave,
  UltraDynamicSky, Narrative, Prefabricator, DLSS/FSR3.

## Networking is already configured

`SurrounDead/Config/DefaultEngine.ini` (shipped inside the pak):

```ini
[/Script/Engine.Engine]
!NetDriverDefinitions=ClearArray
+NetDriverDefinitions=(DefName="GameNetDriver",
  DriverClassName="SteamSockets.SteamSocketsNetDriver",
  DriverClassNameFallback="OnlineSubsystemUtils.IpNetDriver")

[OnlineSubsystemSteam]
SteamDevAppId=1645820
SteamAppId=1645820
bEnabled=True
bUseSteamNetworking=True
bAllowP2PPacketRelay=True

[OnlineSubsystem]
DefaultPlatformService=Steam
```

SteamSockets is the primary net driver with IP as fallback, and P2P relay is
on. `OnlineSubsystemSteam` is linked into the shipping exe; Steamworks v1.53
ships under `Engine/Binaries/ThirdParty/`. **Port forwarding should not be
needed.** The community enabler tells people to use Hamachi because it drives
raw IP on 7777, not because Steam P2P is absent.

Same file:

```ini
GlobalDefaultGameMode=/Game/Blueprints/BP_MPGameMode.BP_MPGameMode_C
```

`BP_MPGameMode` **is not in the pak**. The default game mode points at a
multiplayer game mode that was never shipped. Levels override it with
`BP_SurroundeadGameMode` so the line is inert, but it says MP was scaffolded.

## Replication coverage

Scanned all 1,444 packaged Blueprints for `OnRep_*`, `Server*`/`Multicast*`/
`Client*` RPCs, `HasAuthority`, `bReplicates`. Raw output in
`research/replication_scan_*.txt`.

| Area | Assets | Any markers |
|---|---|---|
| `Content/Blueprints` | 845 | 63 |
| `Content/AI` + `SmartAI` + `Infestation` | 599 | 35 |

Where it clusters:

- `BP_PlayerCharacter` — 28. `OnRep_` for every equipment slot, plus
  `ServerInteract`, `ServerExecuteInteract`, `ServerFuncChangeActiveSlot`,
  `ServerFunc_UpdateDurabilityByUID`. This is Jigsaw Inventory's MP layer,
  largely intact.
- `JigSInventory` ships `BP_JigMultiplayer` and `BP_MpInteractInterface`.
- `BP_SmartAIComponent` — 17. Server-authoritative capable.
- Doors, keypads, turrets, generators, vehicles, building system — 2–4 each,
  mostly bare `HasAuthority` gates.

Where it doesn't:

- `BP_SurroundeadGameMode` — 0. Derives from `GameModeBase`.
- `BP_SurroundeadGameState` — 0.
- `BP_PlayerController` — 1 (`ClientStartCameraShake`).
- `SD_GameInstance` — **no session logic at all.** No CreateSession,
  FindSessions, JoinSession, no travel handling, no lobby.

The static scan can't see CDO defaults that were never overridden. `SDMPDiag`
reads the live values.

## Order of work

1. Session layer — Steam lobbies and a host/join UI. `open <ip>:7777` is the
   only entry point today.
2. A real `BP_MPGameMode` — spawning and possession. This is why the existing
   enabler needs `tphost`/`mprespawn`.
3. World-state authority audit — loot, doors, building, day/night, hordes.
4. Saves — EasyMultiSave documents MP support but saves per-actor. Non-host
   inventories need explicit handling.

---

# Live diagnostics, 2026-09-28

First `SDMPDiag` run, single-player, `PersistentLevel`. The static pak scan
undercounted badly — it only catches Blueprints with explicit replication
markers, and misses everything that inherits `bReplicates` from a parent or a
marketplace plugin's base class.

**4,266 of 22,583 actors in the loaded world already replicate — 18.9%.**

CDO defaults, read live:

| Class | bReplicates | bReplicateMovement | bAlwaysRelevant | NetUpdateFreq |
|---|---|---|---|---|
| `BP_PlayerCharacter` | **true** | true | false | 100 |
| `BP_SurroundeadGameState` | **true** | false | **true** | 10 |
| `BP_VehicleMaster` | **true** | true | false | 100 |
| `Buildable_MASTER` | **true** | false | false | 100 |
| `BP_SurroundeadGameMode` | false | false | false | 10 |
| `BP_PlayerController` | **false** | false | false | 100 |

GameMode reporting false is correct and expected — game modes are
server-only and never replicate.

Top replicating actors in the world:

```
 856  BP_AISpawner_Zombies_C
 242  Container_RandomLoot_TrashBag_C
 146  Container_RandomLoot_TrashPile_C
  95  Container_ResidentialLoot_Cupboard1_C
  92  Container_IndustrialLoot_CrateWall_C
  79  BP_Landmine_C
  78  BP_HarvestableObject_ScrapMetal_C
  52  BP_AISpawner_Animals_C
  47  BP_BarbedWire_C
```

Every loot container class replicates. So do the zombie spawners, the animal
spawners, landmines, barbed wire, harvestables, vehicles and buildables.

## What changed in the plan

This is much better than the static scan implied. The world layer is largely
replication-ready out of the box — it reads like the dev built on marketplace
systems that ship with replication and simply never wired up a session.

The one value worth chasing is **`BP_PlayerController` with
`bReplicates=false`**. Engine `APlayerController` sets it true in its
constructor, so either the Blueprint explicitly unchecked Replicates in class
defaults — plausible for a single-player game trimming overhead, and a hard
blocker for clients — or the Lua read is hitting a stale bitfield. The next
diag run dumps `/Script/Engine.Default__PlayerController` alongside it, which
settles it: if the engine CDO also reads false, it's a read artifact and means
nothing.

Revised order of work:

1. Settle the `BP_PlayerController` replication value.
2. Two clients on a listen server. Most of the world should already sync —
   find out what doesn't rather than assuming.
3. Session layer — Steam lobbies and host/join UI.
4. Saves for non-host players.

## The PlayerController flag was a false alarm

Second diag run dumped the engine CDOs alongside the game's:

```
Default__BP_PlayerController_C  ->  bReplicates=false  bOnlyRelevantToOwner=true
Default__PlayerController       ->  bReplicates=false  bOnlyRelevantToOwner=true
```

The engine's own `APlayerController` CDO reads exactly the same. `bReplicates`
isn't stored where this read looks for a PlayerController, so the value is
meaningless for that class — and the Blueprint matches stock in every field.
The dev did not disable controller replication. Nothing to fix.

`Default__Character` reads `bReplicates=true` and `BP_PlayerCharacter` matches,
which is the consistency check that makes the rest of the table trustworthy.

Class chains:

```
BP_PlayerController_C  <-  BP_MasterPlayerController_C  <-  PlayerController  <-  Controller
BP_SurroundeadGameMode_C  <-  GameModeBase
```

`BP_MasterPlayerController` (`Content/Blueprints/Other/More/`) has zero
replication markers — it's a thin intermediate, not where Jigsaw's MP layer
lives. That's all on `BP_PlayerCharacter`.

## The actual work list

Of the non-replicating actors, most are correctly non-replicating: 16,875
`StaticMeshActor` (world geometry), plus spawn volumes, prefab spawners,
`PlayerStart`, build-exclusion zones, splines and water boxes — all server-side
or static by design.

What's left is the real list — things a second player will interact with that
currently have no authority model:

| Class | Count | Why it matters |
|---|---|---|
| `BP_POIManager_C` | 187 | POI state, likely loot gating |
| `BP_LaboratoryLight_C` (+`2`,`3`) | 195 | Lab area lighting state |
| `BP_LaboratoryLightSwitch_C` | 55 | Switch → light, needs authority |
| `BP_Ladder_C` | 48 | Traversal |
| `BP_LaboratorySlidingDoor_C` | 39 | Traversal |
| `BP_LockedDoor_C` | 20 | Traversal + key state |
| `BP_ZombieDoor_C` | 16 | Traversal |
| `BP_ToolRequired_Axe_C` | 16 | Gated interaction |
| `BP_ToolRequired_GunLocker_C` | 15 | Gated interaction |
| `BP_WaterWell_C` | 15 | Resource interaction |
| `TrashObject_C` | 141 | Minor, cosmetic |

Doors, switches, ladders and gated interactables. That's a bounded list, not a
rewrite. The Laboratory is the worst-affected area — it's essentially a
single-player set piece.

Next: two clients on a listen server, and find out how much of the replicating
18.8% actually holds up under a real connection.

---

# SteamCore is already in the binary

The user `Engine.ini` lists the marketplace plugins the build ships with, and
one of them is `SteamCore_5.3`. It's linked into the shipping exe — 129 symbol
hits, including the entire matchmaking surface:

```
CreateLobby            CreateLobbyAsync       JoinLobby        JoinLobbyAsync
LeaveLobby             RequestLobbyList       GetLobbyByIndex  GetLobbyOwner
GetLobbyData           SetLobbyData           GetNumLobbyMembers
GetLobbyMemberByIndex  GetLobbyMemberData     GetLobbyMemberLimit
InviteUserToLobby      GameLobbyJoinRequested
AddRequestLobbyListStringFilter / NumericalFilter / DistanceFilter /
  ResultCountFilter / SlotsAvailable / NearValue / CompatibleMembers
```

Plus the delegates: `OnCreateLobby`, `OnJoinLobby`, `OnLobbyChatMsg`,
`OnGameLobbyJoinRequested`, `OnLobbyDataUpdate`, `OnLobbyKicked`.

These are reflected UFunctions, so **UE4SS Lua can call them directly** — no
pak override, no Blueprint editing. That covers the entire session layer we
thought we'd have to build:

- host creates a lobby, writes its address into lobby data
- friends see it, or get invited through the Steam overlay
- `GameLobbyJoinRequested` fires on the joiner, who reads the address and travels

`RequestLobbyList` with filters gives a public server browser too, if we want
one later.

So the revised picture is that neither end of this was the hard part. The
world already replicates, and Steam lobbies are already callable. What's
genuinely missing is the middle: spawning and possessing a second player, and
the ~11 interactable classes with no authority model.

# Testing without a second machine or a second copy

Two processes on one PC over 127.0.0.1. Steam P2P can't do this — both
instances run as the same SteamID and a P2P connection to yourself goes
nowhere — so testing forces the IP net driver via a user config override.
`tools/README.md` has the procedure. Single player is unaffected; standalone
never creates a net driver.

---

# It connects. 2026-09-28

Two instances, loopback, IP net driver patched in from Lua:

```
client   NET: driver=IpNetDriver  connections=0  authority=no (we are a client)  pawn=NONE
client   NET: map=PersistentLevel  actors=22480
host     NET: driver=IpNetDriver  connections=1  authority=yes  pawn=BP_PlayerCharacter_C  role=Authority
host     NET: map=PersistentLevel  actors=22595
```

The client is connected and has **22,480 actors** of the host's world — within
a hundred of the host's own count. The world replicates. That was the open
question and the answer is yes.

What's missing is one thing: `pawn=NONE`. The client is a connected observer
with no body.

## Why nothing spawns

`BP_SurroundeadGameMode` has no login hooks whatsoever — its only event is
`ReceiveBeginPlay`. No `PostLogin`, no `HandleStartingNewPlayer`, no
`SpawnDefaultPawn`. It never spawns anyone, which is fine for single player
because the load-save flow does it.

But `BP_PlayerController` already has a server-side respawn path, written for
the game's own death flow:

```
Svr_RequestRespawn_Random
Svr_RequestRespawn_SpawnPoint
Svr_RequestRespawnSuicide
Survival_Respawn
PlayerRespawned (delegate)
ReceivePossess
RespawnScreen widget
```

`Svr_` is the game's own server-RPC prefix. So the mechanism for putting a
player into the world on demand exists and is already server-authoritative —
it just never fires for someone who arrives by connecting rather than dying.

`sdmp_spawn` tries them in order on a pawnless controller. If the game's own
respawn path works for a joiner, the spawning blocker is a few lines of glue
rather than a new game mode.
