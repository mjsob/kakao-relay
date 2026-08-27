' Launch a PowerShell script with no window at all.
' Task Scheduler's "-WindowStyle Hidden" still creates a console for an instant,
' which shows up as a flashing window. WScript.Shell.Run with style 0 does not.
'   usage: wscript.exe run-hidden.vbs "C:\path\to\Script.ps1"
Option Explicit
Dim sh, target, cmd
If WScript.Arguments.Count < 1 Then WScript.Quit 1
target = WScript.Arguments(0)
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File """ & target & """"
sh.Run cmd, 0, False
