@echo off
rem Double-click to install Safe Background Task Killer (creates Desktop + Start Menu shortcuts).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
pause
