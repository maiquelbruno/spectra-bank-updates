@echo off
title Spectra Bank - Sincronizacao automatica do GitHub

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-sync-spectra-bank-v1.ps1"

pause
