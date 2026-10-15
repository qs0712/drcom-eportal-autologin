@echo off
chcp 936 >nul
rem ============================================================
rem  校园网自动登录 - 配置体检
rem  双击运行，会检查配置格式、守护进程状态，并实测一次登录
rem  本文件编码：GBK  换行：CRLF
rem ============================================================
cd /d "%~dp0"
if not exist "%~dp0体检.ps1" (
  echo.
  echo   [错误] 本目录下找不到 体检.ps1
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0体检.ps1"
