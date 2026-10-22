@echo off
REM Double-click: joiner picks up an item and opens a loot container. Search the sdmp_*.log files for "LOOT".
call "%~dp0test.bat" loot %*
