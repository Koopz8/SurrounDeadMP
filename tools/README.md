# Testing co-op with one copy of the game

You don't need a second machine or a second license. Two processes on one PC,
talking over 127.0.0.1.

## One-time setup

The `SDMP LOOPBACK TEST` block in
`%LOCALAPPDATA%\SurrounDead\Saved\Config\Windows\Engine.ini` swaps the net
driver from SteamSockets to IP. This is required: Steam P2P routes by SteamID,
and two instances run by the same account share one, so a P2P connection to
yourself goes nowhere. IP over loopback has no such problem.

It does nothing to single player — standalone never creates a net driver.
Delete the block to restore stock behaviour.

A backup of the original file is at `research/Engine.ini.orig-backup`.

## Running a test

1. Launch the game normally through Steam. Start or load a save so the world
   is fully up.
2. Open the UE console with `~` and run:

   ```
   open PersistentLevel?listen
   ```

   The map reloads as a listen server. `PersistentLevel` is the real game
   world — the community enabler says `LongdownValley`, but the diagnostics
   show `PersistentLevel` is what actually loads.
3. Run `tools\second-instance.bat`. When it's at the menu, `~` and:

   ```
   open 127.0.0.1:7777
   ```
4. F7 in both windows. The host should report a `NetDriver` with
   `ClientConnections: 1`; the client should report no `AuthorityGameMode`
   and a `Role=AutonomousProxy` pawn.

## What to watch for

- Client has no pawn at all → spawning/possession, the known blocker.
- Client sees an empty or frozen world → relevance or streaming.
- Loot containers open on one side only → interaction authority.
- Zombies stand still on the client → SmartAI is server-driven, expected;
  the question is whether their *movement* replicates.
