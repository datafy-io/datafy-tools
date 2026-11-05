# Registers datafy-discovery:// for the current user (no administrator needed), pointing at datafy-discovery.exe.
# DEVELOPMENT SCRIPT, not yet tested on Windows. A real installer (MSI) replaces this and must be code-signed.
#
#   .\register-protocol.ps1 -Exe C:\path\to\datafy-discovery.exe
#   .\register-protocol.ps1 -Remove
param(
  [string]$Exe,
  [switch]$Remove
)
$key = 'HKCU:\Software\Classes\datafy-discovery'
if ($Remove) {
  Remove-Item -Recurse -Force $key -ErrorAction SilentlyContinue
  Write-Host 'Removed.'
  return
}
if (-not $Exe -or -not (Test-Path $Exe)) { throw 'Give the path to datafy-discovery.exe with -Exe.' }
$Exe = (Resolve-Path $Exe).Path
New-Item -Force $key | Out-Null
Set-ItemProperty $key '(Default)' 'URL:Datafy Discovery'
Set-ItemProperty $key 'URL Protocol' ''
New-Item -Force "$key\shell\open\command" | Out-Null
# The link is passed as ONE quoted argument; the program validates it and refuses anything it does not trust.
Set-ItemProperty "$key\shell\open\command" '(Default)' "`"$Exe`" `"%1`""
Write-Host "Registered datafy-discovery:// -> $Exe"
