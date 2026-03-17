Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "E:\Github\scripts"
WshShell.Run "C:\Python313\pythonw.exe E:\Github\scripts\internet_failover_monitor.py", 0, False
