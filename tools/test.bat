@echo off
REM One-click two-player test. Launches a host and a client side by side and
REM the mod runs the whole run sheet itself (see "Auto mode" in main.lua).
REM Both windows quit when the client's scripted run is done; results are in
REM ue4ss\UE4SS.log - search for AUTO and ST.
REM
REM Pass "stay" to keep both windows open afterwards:  test.bat stay

set GAME=C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64
set EXE=%GAME%\SurrounDead-Win64-Shipping.exe
set QUIT=-sdmpquit
if /I "%1"=="stay" set QUIT=

REM clear the handoff files from the last run
echo 0> "%GAME%\ue4ss\Mods\SDMPDiag\sdmp_ready.txt"
echo 0> "%GAME%\ue4ss\Mods\SDMPDiag\sdmp_done.txt"

start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=0 -WinY=40 -sdmprole=host -sdmpauto %QUIT%

REM let the host get far enough to read its role before the client starts
timeout /t 20 /nobreak >nul

REM The client starts on the engine's empty Entry map instead of the menu.
REM The menu lives inside PersistentLevel, and joining a host while that map is
REM already in memory crashes the loader on RecastNavMesh-Default - even after
REM travelling away from it first.
start "" "%EXE%" /Engine/Maps/Entry -windowed -ResX=960 -ResY=540 -WinX=980 -WinY=40 -sdmprole=client -sdmpauto %QUIT%
