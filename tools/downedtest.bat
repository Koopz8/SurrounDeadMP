@echo off
REM Double-click: downed / revive test. Client gets downed by zombies, host
REM revives it, then it gets downed again and bleeds out. Search UE4SS.log for "DT" and "DN".
call "%~dp0test.bat" downed %*
