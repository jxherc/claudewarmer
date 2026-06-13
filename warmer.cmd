@echo off
REM shim so `warmer` works from cmd.exe / any shell once this folder is on PATH
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0warmer.ps1" %*
