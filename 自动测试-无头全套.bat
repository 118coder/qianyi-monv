@echo off
set GODOT="D:\Godot_v4.7.2\Godot_v4.7.2-stable_win64_console.exe"
if not exist %GODOT% set GODOT="%~dp0Godot_v4.7.2-stable_win64.exe"
echo === smoke: tactics ===
%GODOT% --headless --path "%~dp0." -s res://tests/smoke.gd
echo === smoke: arpg ===
%GODOT% --headless --path "%~dp0." -s res://tests/smoke_arpg.gd
echo === autoplay: headless full-run ===
%GODOT% --headless --path "%~dp0." -- --autoplay
echo EXITCODE=%ERRORLEVEL%
pause
