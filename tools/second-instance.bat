@echo off
REM Second SurrounDead instance, for loopback co-op testing on one machine.
REM Launches the shipping exe directly - Steam's library blocks a second
REM launch, the exe itself doesn't. Windowed and small so both fit on screen.
REM
REM Needs the SDMP LOOPBACK TEST block in
REM   %%LOCALAPPDATA%%\SurrounDead\Saved\Config\Windows\Engine.ini
REM or this instance will try Steam P2P and fail against its own SteamID.

start "" "C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64\SurrounDead-Win64-Shipping.exe" -windowed -ResX=1280 -ResY=720
