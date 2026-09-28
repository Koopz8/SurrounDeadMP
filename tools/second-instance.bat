@echo off
REM Instance 2 - the client. Launches the exe directly, past Steam's
REM single-instance block. -log so we can see why a connect fails.
start "" "C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64\SurrounDead-Win64-Shipping.exe" -log -windowed -ResX=1280 -ResY=720 -AbsLog=Client.log
