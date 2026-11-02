@echo off
set GODOT="D:\Godot_v4.7.2\Godot_v4.7.2-stable_win64_console.exe"
if not exist %GODOT% set GODOT="%~dp0Godot_v4.7.2-stable_win64.exe"
echo === autoplay: client mode (watch it play) ===
%GODOT% --path "%~dp0." -- --autoplay
echo EXITCODE=%ERRORLEVEL%
pause
