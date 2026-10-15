@echo off
chcp 936 >nul
rem ============================================================
rem  校园网自动登录（Dr.COM / 城市热点 ePortal）
rem  开机自启：安装 / 卸载 / 查看状态
rem  双击运行即可，无需管理员权限
rem  本文件编码：GBK  换行：CRLF
rem ============================================================
setlocal
set "TASKNAME=DrCom_AutoLogin"
set "PS1=%~dp0drcom-login.ps1"
set "VBS=%~dp0run-hidden.vbs"
set "CFG=%~dp0config.json"
cd /d "%~dp0"

echo.
echo   ============================================
echo     校园网自动登录 - 管理菜单
echo   ============================================
echo.
echo     [1] 安装并立即启动自动登录
echo     [2] 卸载自动登录（停止并删除任务）
echo     [3] 查看运行状态和最近日志
echo     [4] 退出
echo.
choice /c 1234 /n /m "请输入编号 [1/2/3/4]: "
if errorlevel 4 goto 结束
if errorlevel 3 goto 状态
if errorlevel 2 goto 卸载
if errorlevel 1 goto 安装
goto 结束

:安装
if not exist "%PS1%" (
  echo.
  echo   [错误] 本目录下找不到 drcom-login.ps1，文件可能不完整。
  goto 结束
)
if not exist "%CFG%" (
  echo.
  echo   [错误] 本目录下找不到 config.json，文件可能不完整。
  goto 结束
)
powershell -NoProfile -Command "$c=Get-Content -LiteralPath '%CFG%' -Raw -Encoding UTF8|ConvertFrom-Json; if([string]::IsNullOrWhiteSpace($c.username) -or [string]::IsNullOrWhiteSpace($c.password)){exit 1}else{exit 0}"
if errorlevel 1 (
  echo.
  echo   [警告] config.json 里的账号或密码还是空的。
  echo          请先用记事本填好，否则任务启动后会直接报错退出。
  echo.
  pause
)
echo.
echo   正在创建计划任务 %TASKNAME% ...
schtasks /Create /TN "%TASKNAME%" /TR "wscript.exe \"%VBS%\"" /SC ONLOGON /RL LIMITED /F
if errorlevel 1 (
  echo.
  echo   [失败] 计划任务创建失败，请把上面的报错内容发出来。
  goto 结束
)
echo.
echo   [成功] 已创建：登录 Windows 后自动启动，断线自动重登。
echo.
echo   现在立即启动一次 ...
schtasks /Run /TN "%TASKNAME%" >nul 2>&1
if errorlevel 1 (
  echo.
  echo   [提示] 立即启动失败，但这不影响开机自启。
  echo          你可以在下次登录 Windows 后自动生效，
  echo          也可以直接双击「登录一次.bat」立刻登录。
) else (
  timeout /t 5 /nobreak >nul
  echo.
  echo   启动完成。
)
echo   运行日志：%~dp0drcom.log
goto 结束

:卸载
echo.
echo   正在停止并删除计划任务 %TASKNAME% ...
schtasks /End /TN "%TASKNAME%" >nul 2>&1
rem /End 只停任务实例，手动 powershell 起的守护进程要在这里补杀：
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*drcom-login.ps1*' -and $_.CommandLine -notlike '*CimInstance*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
schtasks /Delete /TN "%TASKNAME%" /F
if errorlevel 1 (
  echo.
  echo   [提示] 该任务本来就没有安装，无需卸载。
) else (
  echo.
  echo   [成功] 已卸载，以后不会再自动登录。
)
echo   注意：已在后台运行的 powershell 进程可能仍在跑，注销或重启后彻底消失。
goto 结束

:状态
echo.
echo   ---------- 计划任务 ----------
schtasks /Query /TN "%TASKNAME%" /FO LIST 2>nul
if errorlevel 1 echo   [提示] 该任务尚未安装。

echo.
echo   ---------- 联网状态 ----------
if exist "%PS1%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Status
) else (
  echo   [错误] 找不到 drcom-login.ps1
)

echo.
echo   ---------- 最近日志（最多 15 行）----------
if exist "%~dp0drcom.log" (
  powershell -NoProfile -Command "Get-Content -LiteralPath '%~dp0drcom.log' -Tail 15 -Encoding UTF8"
) else (
  echo   [空] 还没有日志，说明任务可能从未运行过。
)
goto 结束

:结束
echo.
pause
endlocal
