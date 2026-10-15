' 隐藏窗口启动 drcom-login.ps1（供计划任务调用，不弹黑框）
Option Explicit
Dim shell, fso, base, ps1
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = base & "\drcom-login.ps1"
shell.CurrentDirectory = base
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
