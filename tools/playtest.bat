@echo off
REM Real co-op flow (sdmp_host / sdmp_join, no test automation) with two
REM copies on this PC. -sdmpplaytest only makes the host press Continue for you
REM and the joiner wait until the host is in game. Nothing quits on its own.
REM Logs: ue4ss\Mods\SDMPDiag\sdmp_host.log and sdmp_client.log

set GAME=C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64
set EXE=%GAME%\SurrounDead-Win64-Shipping.exe
echo 0> "%GAME%\ue4ss\Mods\SDMPDiag\sdmp_ready.txt"

start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=0 -WinY=40 -sdmplowgfx -sdmpplaytest -sdmpplay=host
timeout /t 20 /nobreak >nul
start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=980 -WinY=40 -sdmplowgfx -sdmpplaytest -sdmpplay=join:127.0.0.1
