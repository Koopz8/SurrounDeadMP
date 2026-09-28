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
