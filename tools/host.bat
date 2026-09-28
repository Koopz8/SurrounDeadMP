@echo off
REM Instance 1 - the host. Steam must be running.
REM -log gives a console window and writes Saved\Logs\SurrounDead.log.
REM Shipping builds write no log at all without it, which is why the first
REM attempt gave us nothing to look at.
start "" "C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64\SurrounDead-Win64-Shipping.exe" -log -windowed -ResX=1280 -ResY=720
