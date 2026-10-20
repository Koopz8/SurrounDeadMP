@echo off
REM Double-click: door sync test. Host and joiner go to the nearest door, the host
REM opens it, then the joiner does. Search the sdmp_*.log files for "DOOR" and "DR:".
call "%~dp0test.bat" door %*
