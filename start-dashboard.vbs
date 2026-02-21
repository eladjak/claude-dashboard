Set WshShell = CreateObject("WScript.Shell")

' Start the Node.js server silently (no CMD window)
WshShell.CurrentDirectory = WshShell.ExpandEnvironmentStrings("%USERPROFILE%") & "\.claude\dashboard"
WshShell.Run "node server.js", 0, False

' Wait 2 seconds for server to start
WScript.Sleep 2000

' Open dashboard in default browser
WshShell.Run "http://localhost:3456", 1, False
