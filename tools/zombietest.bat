@echo off
REM Double-click: zombie-damage test (client stands next to zombies, no god mode).
REM Results: search UE4SS.log for "ZT".
call "%~dp0test.bat" zombie %*
