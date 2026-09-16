#Requires -RunAsAdministrator
<#
  Bitcoin Xor - build your own blocks: one-command DATUM setup for Windows
  ---------------------------------------------------------------------------
  Installs, on this PC, everything needed to mine on the Bitcoin BLAKE2b chain with YOUR OWN block templates:
     * Bitcoin Knots (BLAKE2b fork) v29.4.1 - pruned full node, RPC local-only
     * ratum-gateway 0.1.28            - the DATUM gateway your ASICs connect to on port 23334
  and points the gateway at the Bitcoin Xor DATUM pool for the payout split (1% fee).
  Both run as scheduled tasks that start with Windows (no login needed). Nothing is sent anywhere.
  Safe to re-run: an existing install is updated in place; chain data is kept.

  Usage:  right-click PowerShell -> Run as administrator, then:
          powershell -ExecutionPolicy Bypass -File setup-datum.ps1
  Source: https://github.com/bitcoinxor/datum-in-a-box   Questions: https://t.me/bitcoinxor
#>
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SETUP_VERSION = "v1.2.1"
$KNOTS_VER  = "29.4.1.knots20260508"
$RATUM_VER  = "0.1.28"
$POOL_HOST  = "datum.xorpool.com"; $POOL_PORT = 28915
$POOL_PUBKEY = "b83aedbba54ba2aa605c76859d97aebd16dece3284402b9fc874778a974da4acbb449f6ccda61625d700036f0487a05f5184f79a07abf2880da77352f4cc487e"
$POOL_URL   = "https://xorpool.com/datum"
$SNAPSHOT_URL = "https://snapshot.xorpool.com/latest.json"
$PEER1 = "stratum.xorpool.com:18901"; $PEER2 = "datum.xorpool.com:8333"

$ROOT = "C:\XorDatum"; $BIN = "$ROOT\bin"; $NODE = "$ROOT\node"; $GW = "$ROOT\gateway"; $LOGS = "$ROOT\logs"; $TMP = "$ROOT\tmp"
$GW_CONF = "$GW\gateway.json"; $NODE_CONF = "$NODE\bitcoin.conf"
$STRATUM_PORT = 23334; $MIN_DISK_GB = 25

function Say($s) { Write-Host $s }
function Ok($s) { Write-Host "OK  $s" -ForegroundColor Green }
function Warn($s) { Write-Host "WARNING  $s" -ForegroundColor Yellow }
function Die($s) { Write-Host ""; Write-Host "ERROR  $s" -ForegroundColor Red; Write-Host "Nothing has been deleted; fix the cause and run the script again."; exit 1 }
function Ask($prompt, $default) {
  while ($true) {
    $p = if ($default) { "$prompt [$default]" } else { $prompt }
    $v = Read-Host $p
    if (-not $v) { $v = $default }
    if ($v) { return $v.Trim() }
    Say "  (this one is required)"
  }
}
function ConfirmYes($prompt) { $a = Read-Host "$prompt [Y/n]"; return (-not ($a -match '^(n|no)$')) }
function ConfirmNo($prompt)  { $a = Read-Host "$prompt [y/N]"; return ($a -match '^(y|yes)$') }

# ---------------------------------------------------------------- address validation (bech32 / bech32m / base58check)
function Test-Address([string]$a) {
  $a = $a.Trim()
  if ($a.ToLower().StartsWith("bc1")) {
    if ($a -cne $a.ToLower() -and $a -cne $a.ToUpper()) { return $false }
    $a = $a.ToLower(); $p = $a.LastIndexOf("1")
    if ($p -lt 1 -or ($p + 7) -gt $a.Length -or $a.Substring(0, $p) -ne "bc") { return $false }
    $CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"; $data = @()
    foreach ($c in $a.Substring($p + 1).ToCharArray()) { $i = $CH.IndexOf($c); if ($i -lt 0) { return $false }; $data += $i }
    $hb = [int][char]'b'; $hc = [int][char]'c'
    $vals = @(($hb -shr 5), ($hc -shr 5), 0, ($hb -band 31), ($hc -band 31)) + $data   # hrp expansion for "bc"
    $gen = @(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3); [uint32]$chk = 1
    foreach ($x in $vals) {
      $b = [uint32]($chk -shr 25); $chk = [uint32]((($chk -band 0x1ffffff) -shl 5) -bxor $x)
      for ($i = 0; $i -lt 5; $i++) { if ((($b -shr $i) -band 1) -eq 1) { $chk = $chk -bxor [uint32]$gen[$i] } }
    }
    $ver = $data[0]
    if ($ver -eq 0 -and $chk -ne 1) { return $false }
    if ($ver -gt 0 -and $chk -ne 0x2bc830a3) { return $false }
    $acc = 0; $bits = 0; $n = 0
    for ($i = 1; $i -lt ($data.Count - 6); $i++) { $acc = ($acc -shl 5) -bor $data[$i]; $bits += 5; while ($bits -ge 8) { $bits -= 8; $n++ } }
    return (($ver -eq 0 -and ($n -eq 20 -or $n -eq 32)) -or ($ver -eq 1 -and $n -eq 32))
  }
  if ($a.Length -gt 0 -and "13".Contains([string]$a[0])) {
    # base58 decode with plain integer long division (no BigInteger: its operators misbehave in PowerShell 5.1)
    $alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; $bytes = New-Object System.Collections.Generic.List[int]   # NOT $A: PowerShell variables are case-insensitive, $A would clobber $a
    foreach ($c in $a.ToCharArray()) {
      $carry = $alphabet.IndexOf($c); if ($carry -lt 0) { return $false }
      for ($j = 0; $j -lt $bytes.Count; $j++) { $carry += $bytes[$j] * 58; $bytes[$j] = $carry -band 0xff; $carry = $carry -shr 8 }
      while ($carry -gt 0) { $bytes.Add($carry -band 0xff); $carry = $carry -shr 8 }
    }
    $pad = 0; foreach ($c in $a.ToCharArray()) { if ($c -eq '1') { $pad++ } else { break } }
    $body = @($bytes.ToArray()); [array]::Reverse($body)          # little-endian digits -> big-endian bytes
    $raw = New-Object byte[] ($pad + $body.Count); for ($i = 0; $i -lt $body.Count; $i++) { $raw[$pad + $i] = [byte]$body[$i] }
    if ($raw.Length -ne 25 -or ($raw[0] -ne 0 -and $raw[0] -ne 5)) { return $false }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash($sha.ComputeHash([byte[]]$raw[0..20]))
    for ($i = 0; $i -lt 4; $i++) { if ($h[$i] -ne $raw[21 + $i]) { return $false } }
    return $true
  }
  return $false
}

function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower() }
function Download([string]$url, [string]$out) {
  try { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -Headers @{ "User-Agent" = "setup-datum/$SETUP_VERSION" } }
  catch { Die "download failed: $url ($($_.Exception.Message))" }
}
function TaskExists($n) { return [bool](Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) }
function StopTask($n) { if (TaskExists $n) { Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue } }
function NodeCli($args) { & "$BIN\bitcoin-cli.exe" "-datadir=$NODE" "-conf=$NODE_CONF" @args 2>$null }

# ---------------------------------------------------------------- preflight
if (-not [Environment]::Is64BitOperatingSystem) { Die "64-bit Windows is required" }
$os = Get-CimInstance Win32_OperatingSystem
Say ""; Say "Bitcoin Xor - DATUM setup   Knots v$KNOTS_VER + ratum-gateway $RATUM_VER on $($os.Caption)"; Say ""
$memMB = [int]($os.TotalVisibleMemorySize / 1024)
$drive = (Get-Item ($ROOT.Substring(0, 2) + "\")).PSDrive
$freeGB = [int]((Get-PSDrive $ROOT.Substring(0, 1)).Free / 1GB)
$cpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Say "Machine: $cpus CPU, $memMB MB RAM, $freeGB GB free on $($ROOT.Substring(0,2))"
if ($freeGB -lt $MIN_DISK_GB) { Die "need at least $MIN_DISK_GB GB free on $($ROOT.Substring(0,2)) (have $freeGB GB). The pruned node uses ~14 GB plus headroom." }
if ($memMB -lt 3500) { Warn "less than 4 GB RAM - it works, but the first sync will be slow; Windows manages swap on its own" }
$UPDATE = (Test-Path $NODE_CONF) -or (Test-Path $GW_CONF)
if ($UPDATE) { Say ""; Say "An existing install was found in $ROOT. It will be updated in place: binaries refreshed, configs rewritten from your answers, chain data kept." }

# ---------------------------------------------------------------- questions
$oldAddr = ""; $oldName = ""; $oldPool = ""; $oldPass = ""; $oldApi = ""
if ($UPDATE -and (Test-Path $GW_CONF)) {
  try { $g = Get-Content $GW_CONF -Raw | ConvertFrom-Json; $oldAddr = $g.mining.pool_address; $oldName = $g.mining.coinbase_tag_secondary; $oldPool = "$($g.datum.pool_host):$($g.datum.pool_port)"; $oldApi = $g.api.admin_password } catch {}
}
if (Test-Path $NODE_CONF) { $m = Select-String -Path $NODE_CONF -Pattern '^rpcpassword=(.*)$'; if ($m) { $oldPass = $m.Matches[0].Groups[1].Value } }

Say ""; Say "A few questions (most just need Enter)."; Say ""
Say "1) Your payout address. Every block you help find pays this address straight from the coinbase."
Write-Host "   Use a wallet you hold the keys to - NOT an exchange deposit address." -ForegroundColor Yellow -NoNewline; Say " Need a wallet? https://xorpool.com/wallet"
while ($true) {
  $ADDR = (Ask "   Payout address" $oldAddr) -replace '\s', ''
  if (Test-Address $ADDR) { Ok "address checks out"; break }
  Write-Host "   That is not a valid address on this chain (must be bc1q..., bc1p..., 1... or 3..., typed exactly). Try again." -ForegroundColor Red
}
Say ""; Say "2) A name for your blocks. It is written into every block you help find, next to 'Bitcoin Xor', on-chain forever."
Say "   Letters, numbers, spaces and simple punctuation; up to 60 characters."
while ($true) {
  $NAME = (Ask "   Your name / tag" $oldName).Trim()
  if ($NAME.Length -le 60 -and $NAME -match '^[A-Za-z0-9 ._-]+$') { Ok "tag: $NAME"; break }
  Write-Host "   Keep it to letters, numbers, spaces . _ -  and at most 60 characters." -ForegroundColor Red
}
Say ""; Say "3) Which pool endpoint to send shares to. Press Enter for the default. If this PC is in Asia or Europe you can use"
Say "   hk.datum.xorpool.com:28915 or eu.datum.xorpool.com:28915 instead - same pool, same payout, just closer."
while ($true) {
  $def = if ($oldPool -and $oldPool -ne ":") { $oldPool } else { "${POOL_HOST}:$POOL_PORT" }
  $pool = ((Ask "   DATUM pool (host:port)" $def) -replace '\s', '') -replace '^[a-z+]+://', ''
  if ($pool -match ':') { $h = $pool.Substring(0, $pool.LastIndexOf(':')); $p = $pool.Substring($pool.LastIndexOf(':') + 1) } else { $h = $pool; $p = "$POOL_PORT" }
  if ($h -match '^[A-Za-z0-9.-]+$' -and $p -match '^\d{1,5}$' -and [int]$p -ge 1 -and [int]$p -le 65535) {
    try { [System.Net.Dns]::GetHostAddresses($h) | Out-Null; $POOL_HOST = $h; $POOL_PORT = [int]$p; Ok "pool: ${POOL_HOST}:$POOL_PORT"; break }
    catch { Write-Host "   Cannot resolve host '$h' - check the spelling." -ForegroundColor Red; continue }
  }
  Write-Host "   Give it as host:port, e.g. datum.xorpool.com:28915" -ForegroundColor Red
}

$doSnapshot = $false; $snap = $null
try { $snap = Invoke-RestMethod -Uri $SNAPSHOT_URL -TimeoutSec 15 -Headers @{ "User-Agent" = "setup-datum/$SETUP_VERSION" } } catch {}
if ($snap -and $snap.file) {
  $haveH = 0
  if ((Test-Path "$NODE\chainstate") -and (Test-Path "$BIN\bitcoin-cli.exe")) { try { $haveH = [int](NodeCli @("getblockcount")) } catch { $haveH = 0 } }
  if ($haveH -ge [int]$snap.height) { Say ""; Say "Your node is already past the published snapshot (height $haveH); no snapshot needed." }
  elseif ($freeGB -lt 35) { Say ""; Warn "the chain snapshot needs ~35 GB free during install (have $freeGB GB) - skipping it; the node will sync from scratch (1-3 days)" }
  else {
    Say ""; Say "4) Skip the initial sync? A snapshot of the pruned chain at height $($snap.height) ($([int]($snap.size_bytes/1GB)) GB download) is available."
    Say "   With it the node starts at the tip in minutes instead of 1-3 days. You trust this copy of history up to"
    Say "   height $($snap.height) (like any bootstrap); every block after it is verified by your own node."
    if (ConfirmYes "   Download the snapshot?") { $doSnapshot = $true; Ok "snapshot: height $($snap.height)" } else { Say "   ok - syncing from scratch" }
  }
}

$RPC_PASS = if ($oldPass) { $oldPass } else { -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 40 | ForEach-Object { [char]$_ }) }
$API_PASS = if ($oldApi) { $oldApi } else { -join ((48..57 + 97..102) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) }

Say ""; Say "Summary"
Say "  Payout address   $ADDR"; Say "  Block tag        Bitcoin Xor / $NAME"; Say "  Pool             ${POOL_HOST}:$POOL_PORT  (1% fee, you build the templates)"
Say "  Install to       $ROOT  (node pruned, ~14 GB, RPC local-only; both programs start with Windows)"
if ($doSnapshot) { Say "  Snapshot         $($snap.file) -> node starts at height $($snap.height)" }
Say "  Firewall         allow TCP $STRATUM_PORT inbound on private networks (your ASICs)"
Say ""
if (-not (ConfirmNo "Install with these settings?")) { Say "Nothing changed."; exit 0 }

# ---------------------------------------------------------------- install
Say ""; Say "Installing..."
foreach ($d in @($ROOT, $BIN, $NODE, $GW, $LOGS, $TMP)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
StopTask "XorDatum Gateway"; StopTask "XorDatum Node"
if (Test-Path "$BIN\bitcoin-cli.exe") { try { NodeCli @("stop") | Out-Null; Start-Sleep 5 } catch {} }
Get-Process bitcoind, ratum-gateway -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Knots
$curKnots = ""; if (Test-Path "$BIN\bitcoind.exe") { try { $curKnots = (& "$BIN\bitcoind.exe" --version | Select-Object -First 1) } catch {} }
if ($curKnots -match [regex]::Escape("v$KNOTS_VER")) { Ok "Bitcoin Knots v$KNOTS_VER already installed" }
else {
  Say "downloading Bitcoin Knots v$KNOTS_VER (~50 MB)..."
  $kzip = "bitcoin-$KNOTS_VER-win64-pgpverifiable.zip"; $kurl = "https://github.com/bitcoinknots/bitcoin/releases/download/v$KNOTS_VER"
  Download "$kurl/$kzip" "$TMP\$kzip"; Download "$kurl/SHA256SUMS" "$TMP\SHA256SUMS"
  $want = (Select-String -Path "$TMP\SHA256SUMS" -Pattern ("^([0-9a-f]{64})\s+" + [regex]::Escape($kzip) + "$")).Matches
  if (-not $want -or $want.Count -eq 0) { Die "$kzip is not listed in SHA256SUMS" }
  if ((Get-Sha256 "$TMP\$kzip") -ne $want[0].Groups[1].Value.ToLower()) { Remove-Item "$TMP\$kzip" -Force; Die "checksum MISMATCH on $kzip - not installing it" }
  Expand-Archive -Path "$TMP\$kzip" -DestinationPath "$TMP\knots" -Force
  $src = Get-ChildItem "$TMP\knots" -Recurse -Filter bitcoind.exe | Select-Object -First 1
  Copy-Item $src.FullName "$BIN\bitcoind.exe" -Force; Copy-Item (Join-Path $src.DirectoryName "bitcoin-cli.exe") "$BIN\bitcoin-cli.exe" -Force
  Ok ((& "$BIN\bitcoind.exe" --version | Select-Object -First 1))
}
# ratum
$curRatum = ""; if (Test-Path "$BIN\ratum-gateway.exe") { try { $curRatum = (& "$BIN\ratum-gateway.exe" --version 2>&1 | Select-Object -First 1) } catch {} }
if ($curRatum -match " $RATUM_VER ") { Ok "ratum-gateway $RATUM_VER already installed" }
else {
  Say "downloading ratum-gateway $RATUM_VER (~3 MB)..."
  $rzip = "ratum-gateway-$RATUM_VER-x86_64-windows.zip"; $rurl = "https://github.com/iohzrd/ratum/releases/download/v$RATUM_VER"
  Download "$rurl/$rzip" "$TMP\$rzip"; Download "$rurl/$rzip.sha256" "$TMP\$rzip.sha256"
  $want = ((Get-Content "$TMP\$rzip.sha256" -Raw) -split '\s+')[0].ToLower()
  if ((Get-Sha256 "$TMP\$rzip") -ne $want) { Remove-Item "$TMP\$rzip" -Force; Die "checksum MISMATCH on $rzip - not installing it" }
  Expand-Archive -Path "$TMP\$rzip" -DestinationPath "$TMP\ratum" -Force
  $src = Get-ChildItem "$TMP\ratum" -Recurse -Filter ratum-gateway.exe | Select-Object -First 1
  if (-not $src) { Die "ratum-gateway.exe not found in the archive" }
  Copy-Item $src.FullName "$BIN\ratum-gateway.exe" -Force
  Ok ((& "$BIN\ratum-gateway.exe" --version 2>&1 | Select-Object -First 1))
}

# node config (chain data untouched)
$curl = "$env:SystemRoot\System32\curl.exe"
@"
# Bitcoin Knots (BLAKE2b fork) - written by setup-datum.ps1 on $(Get-Date -Format yyyy-MM-dd)
server=1
disablewallet=1
prune=2000
txindex=0
dbcache=$(if ($memMB -ge 7000) { 2000 } else { 600 })
maxmempool=200
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcuser=knots
rpcpassword=$RPC_PASS
dnsseed=0
fixedseeds=0
addnode=$PEER1
addnode=$PEER2
# Tell the gateway the instant a new block arrives (HTTP notify; Windows has no signals)
blocknotify=$curl -s -m 3 http://127.0.0.1:8000/NOTIFY
"@ | Set-Content -Path $NODE_CONF -Encoding ASCII
Ok "node config $NODE_CONF"

# gateway config
$cfg = [ordered]@{
  bitcoind = [ordered]@{ rpcurl = "http://127.0.0.1:8332"; rpcuser = "knots"; rpcpassword = $RPC_PASS; work_update_seconds = 40; notify_fallback = $true }
  mining   = [ordered]@{ pool_address = $ADDR; coinbase_tag_primary = $NAME; coinbase_tag_secondary = $NAME }
  stratum  = [ordered]@{ listen_addr = "0.0.0.0"; listen_port = $STRATUM_PORT }
  datum    = [ordered]@{ pool_host = $POOL_HOST; pool_port = $POOL_PORT; pool_pubkey = $POOL_PUBKEY; pool_url = $POOL_URL; pool_pass_full_users = $false; pool_pass_workers = $true; gateway_fee_bps = 0; pooled_mining_only = $true }
  api      = [ordered]@{ listen_addr = "127.0.0.1"; listen_port = 8000; admin_password = $API_PASS }
}
$cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $GW_CONF -Encoding ASCII
Ok "gateway config $GW_CONF"

# scheduled tasks: start with Windows as SYSTEM, restart if they die; gateway output to a log file
$sysPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
$trig = New-ScheduledTaskTrigger -AtStartup
$nodeAction = New-ScheduledTaskAction -Execute "$BIN\bitcoind.exe" -Argument "-datadir=$NODE -conf=$NODE_CONF"
$gwAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"`"$BIN\ratum-gateway.exe`" -c `"$GW_CONF`" >> `"$LOGS\gateway.log`" 2>&1`""
Register-ScheduledTask -TaskName "XorDatum Node" -Action $nodeAction -Trigger $trig -Principal $sysPrincipal -Settings $settings -Force | Out-Null
Register-ScheduledTask -TaskName "XorDatum Gateway" -Action $gwAction -Trigger $trig -Principal $sysPrincipal -Settings $settings -Force | Out-Null
Ok "scheduled tasks (start with Windows)"

# firewall: the gateway port, private/domain networks only (your ASICs); the node's RPC stays local
if (-not (Get-NetFirewallRule -DisplayName "XorDatum gateway $STRATUM_PORT" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "XorDatum gateway $STRATUM_PORT" -Direction Inbound -Protocol TCP -LocalPort $STRATUM_PORT -Profile Private, Domain -Action Allow | Out-Null
}
Ok "firewall rule for port $STRATUM_PORT (private networks)"

# status helper
@'
$BIN="C:\XorDatum\bin"; $NODE="C:\XorDatum\node"
function cli { & "$BIN\bitcoin-cli.exe" "-datadir=$NODE" "-conf=$NODE\bitcoin.conf" @args 2>$null }
$n = (Get-Process bitcoind -ErrorAction SilentlyContinue) -ne $null; $g = (Get-Process ratum-gateway -ErrorAction SilentlyContinue) -ne $null
Write-Host ("node:     " + $(if ($n) {"running"} else {"NOT running"}) + "    gateway: " + $(if ($g) {"running"} else {"NOT running"}))
try { $i = cli getblockchaininfo | ConvertFrom-Json; $p = [math]::Round($i.verificationprogress*100,2)
  if ($p -gt 99.99) { Write-Host "chain:    height $($i.blocks)  at tip" } else { Write-Host "chain:    height $($i.blocks)  syncing $p%" }
  Write-Host "peers:    $(cli getconnectioncount)" } catch { Write-Host "chain:    node starting / not answering RPC yet" }
try { $s = Invoke-RestMethod http://127.0.0.1:8000/stats.json -TimeoutSec 3
  Write-Host ("gateway:  {0:N2} TH/s   shares accepted {1}   rejected {2}" -f $s.stratum.hashrate_ths, $s.shares_accepted.count, $s.shares_rejected.count) } catch { Write-Host "gateway:  waiting for the node / not answering yet" }
Write-Host "log:      C:\XorDatum\logs\gateway.log   node: C:\XorDatum\node\debug.log"
'@ | Set-Content -Path "$ROOT\datum-status.ps1" -Encoding ASCII

Start-ScheduledTask -TaskName "XorDatum Node"; Start-Sleep 3; Start-ScheduledTask -TaskName "XorDatum Gateway"; Start-Sleep 4
if (-not (Get-Process bitcoind -ErrorAction SilentlyContinue)) { Die "the node did not start - see $NODE\debug.log" }
if (-not (Get-Process ratum-gateway -ErrorAction SilentlyContinue)) { Die "the gateway did not start - see $LOGS\gateway.log" }

# snapshot
if ($doSnapshot) {
  Say ""; Say "Downloading the chain snapshot ($([int]($snap.size_bytes/1GB)) GB) - this is the long part, a few minutes on a good link..."
  $f = "$TMP\$($snap.file)"
  try { Start-BitsTransfer -Source "https://snapshot.xorpool.com/$($snap.file)" -Destination $f -DisplayName "chain snapshot" -Description "$($snap.file)" }
  catch { Warn "BITS download failed ($($_.Exception.Message)); trying a plain download"; Download "https://snapshot.xorpool.com/$($snap.file)" $f }
  Say "verifying checksum..."
  if ((Get-Sha256 $f) -ne $snap.sha256.ToLower()) { Remove-Item $f -Force; Die "snapshot checksum MISMATCH - not using it. Run the script again to re-download." }
  Ok "checksum matches"
  StopTask "XorDatum Gateway"; try { NodeCli @("stop") | Out-Null } catch {}; StopTask "XorDatum Node"; Start-Sleep 5
  Get-Process bitcoind -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item "$NODE\blocks", "$NODE\chainstate" -Recurse -Force -ErrorAction SilentlyContinue
  $tar = "$env:SystemRoot\System32\tar.exe"
  & $tar -xf $f -C $NODE
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$NODE\chainstate")) { Die "could not extract the snapshot (this Windows tar may lack zstd support). Re-run the script and answer n to the snapshot; the node will sync from scratch." }
  Remove-Item $f -Force
  Start-ScheduledTask -TaskName "XorDatum Node"; Start-Sleep 3; Start-ScheduledTask -TaskName "XorDatum Gateway"
  $got = ""; for ($i = 0; $i -lt 90; $i++) { try { $got = (NodeCli @("getblockhash", "$($snap.height)")); if ($got) { break } } catch {}; Start-Sleep 2 }
  if ($got -and $got.Trim() -eq $snap.block_hash) { Ok "node started from the snapshot at height $($snap.height); block hash verified" }
  else { Warn "could not verify block $($snap.height) against the published hash yet (node still starting?) - check later with datum-status" }
}
Remove-Item "$TMP\*" -Recurse -Force -ErrorAction SilentlyContinue

$myip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
Say ""; Write-Host "Done." -ForegroundColor Green; Say ""
Say "  Point your ASICs at:   stratum+tcp://$($myip):$STRATUM_PORT"
Say "                         worker:  anything.rig1   password:  x"; Say ""
if ($doSnapshot) { Say "  The node started from the snapshot and is catching up the last few blocks - your ASICs get work within minutes." }
else { Say "  The node is now syncing the chain from the start - 1 to 3 days on a small PC. Your ASICs get work automatically"; Say "  the moment it reaches the tip; until then the gateway waits. Leave the PC on (and not sleeping)." }
Say ""; Say "  Check on it any time (PowerShell):  powershell -ExecutionPolicy Bypass -File $ROOT\datum-status.ps1"
Say "  Your stats once shares flow:        $POOL_URL/miner/$ADDR"
Say "  Both programs start with Windows automatically. Power settings: make sure the PC does not sleep."
Say ""
& powershell -ExecutionPolicy Bypass -File "$ROOT\datum-status.ps1"
