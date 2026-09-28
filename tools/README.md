# Testing co-op with one copy of the game

Two processes on one PC over 127.0.0.1. No second machine, no second license.

## One-time setup

The `SDMP LOOPBACK TEST` block in
`%LOCALAPPDATA%\SurrounDead\Saved\Config\Windows\Engine.ini` swaps the net
driver from SteamSockets to IP. Required: Steam P2P routes by SteamID, both
instances run as the same account, and a P2P connection to yourself goes
nowhere. Single player is unaffected — standalone never creates a net driver.

Original backed up at `research/Engine.ini.orig-backup`.

## Order matters

`open <map>?listen` reloads the map. The world in SurrounDead isn't in the
map — it's spawned by the new-game / load-save flow — so hosting *after*
you've started playing throws the world away and drops you back to the menu.

So listen first, then start the game.

1. `tools\host.bat` — instance 1. Steam must be running. `-log` gives a
   console window and writes `Saved\Logs\SurrounDead.log`; Shipping builds
   write nothing without it.
2. At the **main menu**, press `~` and run:

   ```
   open /Game/Levels/PersistentLevel?listen
   ```
3. Press **F8**. Want `driver=IpNetDriver`. If it says `NONE (standalone)`
   the listen didn't take — check the console window for `LogNet`.
4. Now start or load a game through the menu as normal.
5. F8 again. Driver should still be there. If it's gone, loading a save
   travels and takes the listen state with it — that's a different problem
   and worth knowing.
6. `tools\second-instance.bat` — instance 2. At its menu, `~` and:

   ```
   open 127.0.0.1:7777
   ```
7. F8 on the client: `authority=no (we are a client)` and a pawn.
   F8 on the host: `connections=1`.

## If a step fails

The console windows are the point. Useful filters:

```
LogNet            connection, driver, travel
LogNetTraffic     packet level
LogOnline         Steam subsystem
LogLoad           map loading
```

`Saved\Logs\SurrounDead.log` for the host, `Saved\Logs\Client.log` for the
second instance.

## Known symptom, first attempt

`open PersistentLevel?listen` from in-game dropped instance 1 to the main
menu, and the client's `open 127.0.0.1:7777` did nothing visible. The first
half is expected — see "Order matters". The second half we have no data on,
because there was no log. Hence `-log`.
