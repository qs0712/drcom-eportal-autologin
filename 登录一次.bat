@echo off
chcp 936 >nul
rem ============================================================
rem  校园网自动登录 - 手动登录一次
rem  断网时双击即可，登录完成后窗口停留在结果页
rem  本文件编码：GBK  换行：CRLF
rem ============================================================
cd /d "%~dp0"

if not exist "%~dp0config.json" (
  echo.
  echo   [错误] 本目录下找不到 config.json，无法读取账号密码。
  echo.
  pause
  exit /b 1
)

echo.
echo   正在检查网络并登录，请稍候 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0drcom-login.ps1" -Once

echo.
echo   --------------------------------------------------
echo   运行日志：%~dp0drcom.log
echo   如需关闭自动登录，请运行「安装-开机自启.bat」并选择 [2]。
echo.
pause
