@echo off
pwsh.exe -NoLogo -NoProfile -File "%~dp0coldshelf.ps1" %*
exit /b %ERRORLEVEL%
