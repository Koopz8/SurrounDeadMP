@echo off
REM Two plain copies of the game side by side, no co-op flags: for trying the
REM real menu keys. Left window: F7 (host), then Continue. Right window, once
REM the host is in game: F8 (join the join_ip in config.txt, 127.0.0.1 by default).
set GAME=C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64
set EXE=%GAME%\SurrounDead-Win64-Shipping.exe
start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=0 -WinY=40 -sdmplowgfx
timeout /t 15 /nobreak >nul
start "" "%EXE%" -windowed -ResX=960 -ResY=540 -WinX=980 -WinY=40 -sdmplowgfx
