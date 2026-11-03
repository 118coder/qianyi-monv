@echo off
rem 可视化创作工坊：不打开 Godot 编辑器，直接进 RPG Maker 式的创作界面
start "" "%~dp0Godot_v4.7.2-stable_win64.exe" --path "%~dp0." "res://creator/creator.tscn"
