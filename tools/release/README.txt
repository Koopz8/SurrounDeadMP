SurrounDead Co-op  -  v0.1.0-beta
===================================

Two-player co-op for SurrounDead. One player hosts their save, a friend
joins it. This is a beta: expect rough edges, and keep a backup of your saves.


INSTALL (both players)
----------------------
1. Find the game folder: in Steam, right-click SurrounDead > Manage >
   Browse local files. Open  SurrounDead\Binaries\Win64
2. Extract everything in this zip into that Win64 folder, so that
   dwmapi.dll sits next to SurrounDead-Win64-Shipping.exe.
3. Start the game. The first start makes
   Win64\ue4ss\Mods\SurrounDeadCoop\config.txt

Both players need the same version of the mod.

To uninstall, delete dwmapi.dll and the ue4ss folder from Win64.


PLAYING
-------
Host:
  - In the main menu press F7, then Continue or Load your save as usual.
  - Your friend needs your IP address. On the same network use your local
    IP (192.168.x.x). Over the internet either forward UDP port 7777 on your
    router to your PC, or both install a virtual LAN (Radmin VPN, ZeroTier,
    Tailscale...) and use the IP it gives you.

Joiner:
  - Open ue4ss\Mods\SurrounDeadCoop\config.txt, set  join_ip=  to the
    host's IP and save it.
  - Wait until the host is in game, then press F8 in the main menu.


WHAT WORKS
----------
  - Both players in the same world, zombies chase and hurt both
  - Downed instead of dead: stand or crouch next to your downed partner for
    5 seconds to revive them. 60 seconds to bleed out. If both of you go
    down, it's game over for real.
  - A joiner who dies respawns next to the host after 10 seconds
  - Time of day and weather match for both players
  - Clothing and gear show up on the other player
  - Doors opened by either player open for both
  - Friendly fire is off (friendly_fire=true in config.txt to turn it on)
  - The host's game keeps the joiner's character (inventory, clothes,
    health) for next time. If the joiner dies, they start fresh, same as
    single player.


KNOWN ISSUES
------------
  - Some movement stutter on the joiner's side. Lower graphics settings help.
  - The zombie attack animation looks a bit off on the joiner's screen.
  - Drinking from wells, building and other world interactions may only
    work for the host.
  - The joiner's character lives in the host's game, so it only comes back
    when joining that same host. Joining needs the host's IP, no Steam
    invites yet.
  - If the host leaves, the joiner is sent back to the main menu.


SETTINGS (config.txt)
---------------------
  join_ip=127.0.0.1        who F8 joins
  friendly_fire=false      can players hurt each other
  bleed_out_seconds=60     time before a downed player dies
  revive_seconds=5         how long a revive takes
  joiner_saves=true        host keeps joiners' characters between sessions
  debug=false              extra logging for bug reports


BUG REPORTS
-----------
Please send the log from ue4ss\Mods\SurrounDeadCoop\  (sdmp_host.log or
sdmp_client.log) and ue4ss\UE4SS.log, and say what happened right before.
Setting debug=true first makes the logs much more useful.


CREDITS
-------
Mod by Koop. Runs on UE4SS (https://github.com/UE4SS-RE/RE-UE4SS, MIT
licence, included in this download). This is an unofficial fan mod and
isn't affiliated with the makers of SurrounDead.
