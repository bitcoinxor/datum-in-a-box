#Requires -RunAsAdministrator
<#
  datum-pool.ps1 - change the DATUM pool your gateway works with (Windows, for a setup made by setup-datum.ps1)
  ---------------------------------------------------------------------------------------------------------
  Asks one thing: which pool. Rewrites the pool part of the gateway config, restarts the gateway, and tells you whether
  the new pool answered and proved its key. Your miners keep pointing at this PC; nothing else changes.

  Usage:  right-click PowerShell -> Run as administrator, then:
          powershell -ExecutionPolicy Bypass -File C:\XorDatum\datum-pool.ps1
  Or without questions:   ... -File C:\XorDatum\datum-pool.ps1 -Pool host:port -Key <128 hex> [-Url https://...]
                          ... -File C:\XorDatum\datum-pool.ps1 -Xor          (back to Bitcoin Xor)
  Source: https://github.com/bitcoinxor/datum-in-a-box
#>
param([string]$Pool = "", [string]$Key = "", [string]$Url = "", [switch]$Xor)
$ErrorActionPreference = "Stop"

$XOR_HOST = "datum.xorpool.com"; $XOR_PORT = 28915
$XOR_PUBKEY = "b83aedbba54ba2aa605c76859d97aebd16dece3284402b9fc874778a974da4acbb449f6ccda61625d700036f0487a05f5184f79a07abf2880da77352f4cc487e"
$XOR_URL = "https://xorpool.com/datum"
$ROOT = if ($env:XORDATUM_ROOT) { $env:XORDATUM_ROOT } else { "C:\XorDatum" }
$GW_CONF = "$ROOT\gateway\gateway.json"; $LOG = "$ROOT\logs\gateway.log"

function Say($s) { Write-Host $s }
function Ok($s) { Write-Host "OK  $s" -ForegroundColor Green }
function Warn($s) { Write-Host "WARNING  $s" -ForegroundColor Yellow }
function Die($s) { Write-Host ""; Write-Host "ERROR  $s" -ForegroundColor Red; exit 1 }
function Ask($prompt, $default) {
  while ($true) {
    $v = Read-Host $(if ($default) { "$prompt [$default]" } else { $prompt })
    if (-not $v) { $v = $default }
    if ($v) { return $v.Trim() }
    Say "  (this one is required)"
  }
}
function ParseEndpoint([string]$ep) {   # host:port -> @(host, port) or $null
  $ep = ($ep -replace '\s', '') -replace '^[a-z+]+://', ''
  if ($ep -match ':') { $h = $ep.Substring(0, $ep.LastIndexOf(':')); $p = $ep.Substring($ep.LastIndexOf(':') + 1) } else { $h = $ep; $p = "$XOR_PORT" }
  if ($h -match '^[A-Za-z0-9.-]+$' -and $p -match '^\d{1,5}$' -and [int]$p -ge 1 -and [int]$p -le 65535) {
    try { [System.Net.Dns]::GetHostAddresses($h) | Out-Null; return @($h, [int]$p) } catch { Write-Host "   Cannot resolve host '$h' - check the spelling." -ForegroundColor Red; return $null }
  }
  Write-Host "   Give it as host:port, e.g. datum.xorpool.com:28915" -ForegroundColor Red; return $null
}

if (-not (Test-Path $GW_CONF)) { Die "no gateway config at $GW_CONF - run setup-datum.ps1 first" }
$cfg = Get-Content $GW_CONF -Raw | ConvertFrom-Json
$curKey = ("" + $cfg.datum.pool_pubkey).ToLower()
Say ""; Say ("Current pool: " + $(if ($curKey -eq $XOR_PUBKEY) { "Bitcoin Xor" } else { "key " + $curKey.Substring(0, 8) + "..." }) + " at $($cfg.datum.pool_host):$($cfg.datum.pool_port)")

$newHost = ""; $newPort = 0; $newKey = ""; $newUrl = ""
if ($Xor) { $newHost = $XOR_HOST; $newPort = $XOR_PORT; $newKey = $XOR_PUBKEY; $newUrl = $XOR_URL }
elseif ($Pool -or $Key) {
  if (-not ($Pool -and $Key)) { Die "give both -Pool host:port and -Key <128 hex>, or -Xor" }
  $e = ParseEndpoint $Pool; if (-not $e) { exit 1 }
  $newHost = $e[0]; $newPort = $e[1]; $newKey = ($Key -replace '\s', '').ToLower()
  if ($newKey -notmatch '^[0-9a-f]{128}$') { Die "-Key must be exactly 128 hex characters (got $($newKey.Length))" }
  if ($newKey -eq $XOR_PUBKEY) { $newUrl = $XOR_URL } elseif ($Url -match '^https?://[A-Za-z0-9./_:?=&%~-]+$') { $newUrl = $Url }
} else {
  Say ""; Say "Which DATUM pool should this gateway work with?"
  Say "     1) Bitcoin Xor - xorpool.com   (1% fee)"
  Say "     2) Another DATUM pool          (you need its host:port and its public key, from that pool's site)"
  while ($true) { $c = Ask "   Pool" "1"; if ($c -eq "1" -or $c -eq "2") { break }; Write-Host "   Type 1 or 2." -ForegroundColor Red }
  if ($c -eq "1") {
    Say "   Endpoint: press Enter for the default. In Asia or Europe you can use hk.datum.xorpool.com:28915 or eu.datum.xorpool.com:28915."
    $def = if ($curKey -eq $XOR_PUBKEY) { "$($cfg.datum.pool_host):$($cfg.datum.pool_port)" } else { "${XOR_HOST}:$XOR_PORT" }
    while ($true) { $e = ParseEndpoint (Ask "   DATUM pool (host:port)" $def); if ($e) { break } }
    $newHost = $e[0]; $newPort = $e[1]; $newKey = $XOR_PUBKEY; $newUrl = $XOR_URL
  } else {
    $def = if ($curKey -ne $XOR_PUBKEY) { "$($cfg.datum.pool_host):$($cfg.datum.pool_port)" } else { "" }
    while ($true) { $e = ParseEndpoint (Ask "   The pool's DATUM endpoint (host:port)" $def); if ($e) { break } }
    $newHost = $e[0]; $newPort = $e[1]
    Say "   The pool's public key: 128 hex characters, published by the pool. A wrong key means no mining - paste it exactly."
    while ($true) {
      $k = ((Ask "   Pool public key" $(if ($curKey -ne $XOR_PUBKEY) { $curKey } else { "" })) -replace '\s', '').ToLower()
      if ($k -match '^[0-9a-f]{128}$') { $newKey = $k; break }
      Write-Host "   That is not a DATUM public key (need exactly 128 hex characters, got $($k.Length))." -ForegroundColor Red
    }
    $u = Read-Host "   The pool's web address, optional (Enter to skip)"
    $u = ("" + $u) -replace '\s', ''; if ($u -match '^https?://[A-Za-z0-9./_:?=&%~-]+$') { $newUrl = $u }
  }
}

$cfg.datum.pool_host = $newHost; $cfg.datum.pool_port = $newPort; $cfg.datum.pool_pubkey = $newKey; $cfg.datum.pool_url = $newUrl
$cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $GW_CONF -Encoding ASCII
Ok ("pool set to " + $(if ($newKey -eq $XOR_PUBKEY) { "Bitcoin Xor" } else { "key " + $newKey.Substring(0, 8) + "..." }) + " at ${newHost}:$newPort")

# restart the gateway: stop the task and the process, start the task; the gateway reads the config on start
$logMark = if (Test-Path $LOG) { (Get-Item $LOG).Length } else { 0 }
if (Get-ScheduledTask -TaskName "XorDatum Gateway" -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName "XorDatum Gateway" -ErrorAction SilentlyContinue
  Get-Process ratum-gateway -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep 1
  Start-ScheduledTask -TaskName "XorDatum Gateway"; Say "gateway restarting..."
} else { Warn "scheduled task 'XorDatum Gateway' not found - restart the gateway yourself"; exit 0 }

# did the new pool answer and prove its key?
$link = ""
for ($i = 0; $i -lt 30; $i++) {
  try { $link = "" + (Invoke-RestMethod http://127.0.0.1:8000/stats.json -TimeoutSec 3).status } catch { $link = "" }
  if ($link -eq "Connected and Ready") { break }; Start-Sleep 2
}
$newLog = ""
try { $fs = [System.IO.File]::Open($LOG, 'Open', 'Read', 'ReadWrite'); [void]$fs.Seek([Math]::Min($logMark, $fs.Length), 'Begin'); $sr = New-Object System.IO.StreamReader($fs); $newLog = $sr.ReadToEnd(); $sr.Close(); $fs.Close() } catch {}
if ($link -eq "Connected and Ready") { Ok "pool link up: ${newHost}:$newPort answered and proved its key. Your miners keep mining through this PC." }
elseif ($newLog -match 'DATUM connection ended|DATUM pool is unreachable') {
  Warn "the gateway cannot complete the handshake with ${newHost}:$newPort - wrong host, port or key, or the pool is unreachable."
  Say  "         Nothing is mined until it connects. Check the values with the pool and run this script again. Log: $LOG"
} else { Say ("  gateway status: " + $(if ($link) { $link } else { "not answering yet" }) + " - if the node is still starting this is normal; datum-status shows the pool link later") }
