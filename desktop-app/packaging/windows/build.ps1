# Builds datafy-discovery.exe. Run from desktop-app\.   .\packaging\windows\build.ps1 [-Dev]
# -Dev also trusts http://localhost:3000 (the Vite dev server). The result is UNSIGNED until a certificate signs it.
param([switch]$Dev)
$tags = if ($Dev) { '-tags', 'dev' } else { @() }
# -H=windowsgui: no console window flashes when the browser launches the app.
go build @tags -trimpath -ldflags '-s -w -H=windowsgui' -o packaging\windows\build\datafy-discovery.exe .\cmd\datafy-discovery
Write-Host 'Built packaging\windows\build\datafy-discovery.exe'
