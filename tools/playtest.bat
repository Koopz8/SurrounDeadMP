@echo off
REM Try the real co-op flow (no test automation) with two copies on this PC.
REM 1. The host window opens and starts hosting on its own.
REM    Get past "press any key" and press Continue (or Load) like normal.
REM 2. Once the host is in the game, come back here and press a key.
REM 3. The second window joins 127.0.0.1 by itself.
REM Logs: ue4ss\Mods\SDMPDiag\sdmp_host.log and sdmp_client.log

set GAME=C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64
set EXE=%GAME%\SurrounDead-Win64-Shipping.exe

start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=0 -WinY=40 -sdmplowgfx -sdmpplay=host
echo.
echo Host window starting. Continue into your save there, then press a key here to start the joiner.
pause >nul
start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=980 -WinY=40 -sdmplowgfx -sdmpplay=join:127.0.0.1
