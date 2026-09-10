# DATUM-in-a-box — Windows / WSL2 setup.  Run in an ELEVATED PowerShell.
# Requires: Windows 11 + WSL2 + Docker (Desktop, or docker engine installed inside WSL).

Write-Host "== DATUM-in-a-box (Windows/WSL) setup ==" -ForegroundColor Cyan

# 1. Mirrored networking so ASICs on your LAN can reach the gateway (WSL2 is NAT'd otherwise).
$wslcfg = "$env:USERPROFILE\.wslconfig"
$has = (Test-Path $wslcfg) -and (Select-String -Path $wslcfg -Pattern "networkingMode=mirrored" -Quiet)
if (-not $has) {
  Add-Content -Path $wslcfg -Value "`n[wsl2]`nnetworkingMode=mirrored"
  Write-Host "Enabled WSL mirrored networking. Restarting WSL..." -ForegroundColor Yellow
  wsl --shutdown
}

# 2. Allow the stratum port through Windows Firewall.
if (-not (Get-NetFirewallRule -DisplayName "DATUM-in-a-box 23334" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "DATUM-in-a-box 23334" -Direction Inbound `
    -Action Allow -Protocol TCP -LocalPort 23334 | Out-Null
  Write-Host "Opened firewall port 23334."
}

# 3. Run the Linux setup inside WSL, from this folder.
$wslPath = ($PWD.Path -replace '\\','/' -replace '^([A-Za-z]):','/mnt/$1').ToLower()
Write-Host "Running setup inside WSL at $wslPath ..."
wsl bash -c "cd '$wslPath' && chmod +x setup.sh && ./setup.sh"

Write-Host "Done. Point your miners at  <this-PC-LAN-ip>:23334  (username = your address)." -ForegroundColor Green
