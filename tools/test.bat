@echo off
REM One-click two-player test. Launches a host and a client side by side and
REM the mod runs the whole run sheet itself (see "Auto mode" in main.lua).
REM Both windows quit when the client's scripted run is done; results are in
REM ue4ss\UE4SS.log - search for AUTO and ST.
REM
REM Pass "stay" to keep both windows open afterwards:  test.bat stay
REM Pass "zombie" for the zombie-damage test:          test.bat zombie
REM Pass "downed" for the downed / revive test:         test.bat downed
REM Pass "door" for the door sync test:                 test.bat door
REM Pass "persist"/"well"/"loot"/"build" for those:   test.bat loot
REM (either order, e.g. test.bat zombie stay)

set GAME=C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64
set EXE=%GAME%\SurrounDead-Win64-Shipping.exe
set QUIT=-sdmpquit
if /I "%1"=="stay" set QUIT=
if /I "%2"=="stay" set QUIT=
set TEST=
if /I "%1"=="zombie" set TEST=-sdmptest=zombie
if /I "%2"=="zombie" set TEST=-sdmptest=zombie
if /I "%1"=="downed" set TEST=-sdmptest=downed
if /I "%2"=="downed" set TEST=-sdmptest=downed
if /I "%1"=="door" set TEST=-sdmptest=door
if /I "%2"=="door" set TEST=-sdmptest=door
if /I "%1"=="persist" set TEST=-sdmptest=persist
if /I "%2"=="persist" set TEST=-sdmptest=persist
if /I "%1"=="well" set TEST=-sdmptest=well
if /I "%2"=="well" set TEST=-sdmptest=well
if /I "%1"=="loot" set TEST=-sdmptest=loot
if /I "%2"=="loot" set TEST=-sdmptest=loot
if /I "%1"=="build" set TEST=-sdmptest=build
if /I "%2"=="build" set TEST=-sdmptest=build

REM no test named: the old scripted-movement run is retired (it crashed the
REM client), so just say what to run
if "%TEST%"=="" (
  echo Usage: test.bat zombie^|downed^|door^|persist^|well^|loot^|build [stay]
  echo Or double-click zombietest / downedtest / doortest / persisttest / playtest.
  pause
  exit /b 1
)

REM clear the handoff files from the last run
echo 0> "%GAME%\ue4ss\Mods\SDMPDiag\sdmp_ready.txt"
echo 0> "%GAME%\ue4ss\Mods\SDMPDiag\sdmp_done.txt"
echo 0> "%GAME%\ue4ss\Mods\SDMPDiag\sdmp_phase.txt"

start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=0 -WinY=40 -sdmprole=host -sdmpauto %QUIT% %TEST%

REM let the host get far enough to read its role before the client starts
timeout /t 20 /nobreak >nul

start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=980 -WinY=40 -sdmprole=client -sdmpauto %QUIT% %TEST%
