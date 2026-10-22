@echo off
REM Double-click: joiner places a campfire, host checks it appeared. Search the sdmp_*.log files for "BUILD".
call "%~dp0test.bat" build %*
