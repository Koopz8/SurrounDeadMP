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
