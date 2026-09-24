Set objShell = CreateObject("Shell.Application")
strPath = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
objShell.ShellExecute "powershell.exe", "-ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strPath & "\KillBackgroundApps_GUI.ps1""", "", "runas", 1
