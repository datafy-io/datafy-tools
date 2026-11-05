-- Receives datafy-discovery:// links from macOS and hands each one to the Datafy Discovery program inside this app.
-- It does nothing else: all validation of the link happens in the program, which refuses anything it does not trust.
on open location theURL
	set appPath to POSIX path of (path to me)
	set bin to appPath & "Contents/Resources/datafy-discovery"
	set logFile to (POSIX path of (path to library folder from user domain)) & "Logs/DatafyDiscovery.log"
	-- The link is passed as ONE quoted argument, never interpreted by the shell. The program keeps running in the
	-- background after this launcher exits.
	do shell script quoted form of bin & " " & quoted form of theURL & " >> " & quoted form of logFile & " 2>&1 &"
end open location

on run
	display dialog "Datafy Discovery runs in the background. Open the Datafy page and press Connect." buttons {"OK"} default button "OK" with title "Datafy Discovery"
end run
