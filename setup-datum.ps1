#Requires -RunAsAdministrator
<#
  Bitcoin Xor - build your own blocks: one-command DATUM setup for Windows
  ---------------------------------------------------------------------------
  Installs, on this PC, everything needed to mine on the Bitcoin BLAKE2b chain with YOUR OWN block templates:
     * Bitcoin Knots (BLAKE2b fork) v29.4.2 - pruned full node, RPC local-only
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

$SETUP_VERSION = "v1.6.0"
$KNOTS_VER  = "29.4.2.knots20260508"
$RATUM_VER  = "0.1.28"
# The default pool. Any other DATUM pool works too (question 3): a pool is identified by its PUBLIC KEY, which the
# gateway checks on every connection; host and port only say where to reach it.
$XOR_HOST   = "datum.xorpool.com"; $XOR_PORT = 28915
$XOR_PUBKEY = "b83aedbba54ba2aa605c76859d97aebd16dece3284402b9fc874778a974da4acbb449f6ccda61625d700036f0487a05f5184f79a07abf2880da77352f4cc487e"
$XOR_URL    = "https://xorpool.com/datum"
$POOL_HOST  = $XOR_HOST; $POOL_PORT = $XOR_PORT; $POOL_PUBKEY = $XOR_PUBKEY; $POOL_URL = $XOR_URL
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
function NodeCli { & "$BIN\bitcoin-cli.exe" "-datadir=$NODE" "-conf=$NODE_CONF" @args 2>$null }   # automatic $args - a declared ($args) parameter swallows the arguments and the call returns nothing
function StopAll {
  # gateway first (stateless), then ask the node to shut down and WAIT: Stop-ScheduledTask kills the process outright,
  # and a killed node has not flushed its chainstate - next start it rewinds to the last flush and replays (minutes to hours)
  StopTask "XorDatum Gateway"; Get-Process ratum-gateway -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  if ((Get-Process bitcoind -ErrorAction SilentlyContinue) -and (Test-Path "$BIN\bitcoin-cli.exe")) {
    try { NodeCli stop | Out-Null } catch {}
    Say "  waiting for the node to shut down cleanly..."
    for ($i = 0; $i -lt 180; $i++) { if (-not (Get-Process bitcoind -ErrorAction SilentlyContinue)) { break }; Start-Sleep 1 }
  }
  StopTask "XorDatum Node"; Get-Process bitcoind -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- preflight
if (-not [Environment]::Is64BitOperatingSystem) { Die "64-bit Windows is required" }
$os = Get-CimInstance Win32_OperatingSystem
Say ""; Say "Bitcoin Xor - DATUM setup   Knots v$KNOTS_VER + ratum-gateway $RATUM_VER on $($os.Caption)"; Say ""
$memMB = [int]($os.TotalVisibleMemorySize / 1024)
$drive = (Get-Item ($ROOT.Substring(0, 2) + "\")).PSDrive
$freeGB = [int]((Get-PSDrive $ROOT.Substring(0, 1)).Free / 1GB)
$cpus = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Say "Machine: $cpus CPU, $memMB MB RAM, $freeGB GB free on $($ROOT.Substring(0,2))"
if (Test-Path "$NODE\chainstate") { $MIN_DISK_GB = 5 }   # the node already holds its ~14 GB; an update only needs working room
if ($freeGB -lt $MIN_DISK_GB) { Die "need at least $MIN_DISK_GB GB free on $($ROOT.Substring(0,2)) (have $freeGB GB). The pruned node uses ~14 GB plus headroom." }
if ($memMB -lt 3500) { Warn "less than 4 GB RAM - it works, but the first sync will be slow; Windows manages swap on its own" }
$UPDATE = (Test-Path $NODE_CONF) -or (Test-Path $GW_CONF)
$hadChain = Test-Path "$NODE\chainstate"   # chain data from an earlier run - decides the wording at the end
if ($UPDATE) { Say ""; Say "An existing install was found in $ROOT. It will be updated in place: binaries refreshed, configs rewritten from your answers, chain data kept." }

# ---------------------------------------------------------------- questions
$oldAddr = ""; $oldName = ""; $oldPool = ""; $oldPass = ""; $oldApi = ""; $oldKey = ""; $oldUrl = ""
if ($UPDATE -and (Test-Path $GW_CONF)) {
  try { $g = Get-Content $GW_CONF -Raw | ConvertFrom-Json; $oldAddr = $g.mining.pool_address; $oldName = $g.mining.coinbase_tag_secondary; $oldPool = "$($g.datum.pool_host):$($g.datum.pool_port)"; $oldApi = $g.api.admin_password; $oldKey = ("" + $g.datum.pool_pubkey).ToLower(); $oldUrl = "" + $g.datum.pool_url } catch {}
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
Say ""; Say "3) Which DATUM pool should this gateway work with?"
Say "     1) Bitcoin Xor - xorpool.com   (1% fee; the default)"
Say "     2) Another DATUM pool          (you need its host:port and its public key, from that pool's site)"
$otherPool = ($oldKey -and $oldKey -ne $XOR_PUBKEY)
while ($true) {
  $choice = Ask "   Pool" $(if ($otherPool) { "2" } else { "1" })
  if ($choice -eq "1") { $otherPool = $false; break } elseif ($choice -eq "2") { $otherPool = $true; break }
  Write-Host "   Type 1 or 2." -ForegroundColor Red
}
function AskEndpoint($prompt, $def) {   # sets $script:POOL_HOST / $script:POOL_PORT
  while ($true) {
    $ep = ((Ask $prompt $def) -replace '\s', '') -replace '^[a-z+]+://', ''
    if ($ep -match ':') { $eh = $ep.Substring(0, $ep.LastIndexOf(':')); $epp = $ep.Substring($ep.LastIndexOf(':') + 1) } else { $eh = $ep; $epp = "$XOR_PORT" }
    if ($eh -match '^[A-Za-z0-9.-]+$' -and $epp -match '^\d{1,5}$' -and [int]$epp -ge 1 -and [int]$epp -le 65535) {
      try { [System.Net.Dns]::GetHostAddresses($eh) | Out-Null; $script:POOL_HOST = $eh; $script:POOL_PORT = [int]$epp; return }
      catch { Write-Host "   Cannot resolve host '$eh' - check the spelling." -ForegroundColor Red; continue }
    }
    Write-Host "   Give it as host:port, e.g. datum.xorpool.com:28915" -ForegroundColor Red
  }
}
if (-not $otherPool) {
  Say "   Endpoint: press Enter for the default. In Asia or Europe you can use hk.datum.xorpool.com:28915 or"
  Say "   eu.datum.xorpool.com:28915 instead - same pool, same payout, just closer."
  $defEp = if ($oldKey -eq $XOR_PUBKEY -and $oldPool -and $oldPool -ne ":") { $oldPool } else { "${XOR_HOST}:$XOR_PORT" }
  AskEndpoint "   DATUM pool (host:port)" $defEp
  $POOL_PUBKEY = $XOR_PUBKEY; $POOL_URL = $XOR_URL; Ok "pool: Bitcoin Xor at ${POOL_HOST}:$POOL_PORT"
} else {
  $defEp = if ($oldKey -and $oldKey -ne $XOR_PUBKEY -and $oldPool -ne ":") { $oldPool } else { "" }
  AskEndpoint "   The pool's DATUM endpoint (host:port)" $defEp
  Say "   The pool's public key: 128 hex characters, published by the pool. The gateway refuses to talk to anyone who"
  Say "   cannot prove they hold it, so a wrong key means no mining - paste it exactly."
  while ($true) {
    $keyIn = ((Ask "   Pool public key" $(if ($oldKey -and $oldKey -ne $XOR_PUBKEY) { $oldKey } else { "" })) -replace '\s', '').ToLower()
    if ($keyIn -match '^[0-9a-f]{128}$') { $POOL_PUBKEY = $keyIn; break }
    Write-Host "   That is not a DATUM public key (need exactly 128 hex characters, got $($keyIn.Length))." -ForegroundColor Red
  }
  $defUrl = if ($oldKey -and $oldKey -ne $XOR_PUBKEY) { $oldUrl } else { "" }   # never offer xorpool's address for another pool
  $urlIn = Read-Host ("   The pool's web address, optional (Enter to skip)" + $(if ($defUrl) { " [$defUrl]" } else { "" }))
  if (-not $urlIn) { $urlIn = $defUrl }; $urlIn = ("" + $urlIn) -replace '\s', ''
  if ($urlIn -and $urlIn -notmatch '^https?://[A-Za-z0-9./_:?=&%~-]+$') { Say "   (not a web address - skipping it)"; $urlIn = "" }
  $POOL_URL = $urlIn
  Ok ("pool: ${POOL_HOST}:$POOL_PORT  key " + $POOL_PUBKEY.Substring(0, 8) + "..." + $POOL_PUBKEY.Substring(120))
}
$isXor = ($POOL_PUBKEY -eq $XOR_PUBKEY)

$doSnapshot = $false; $snap = $null
try { $snap = Invoke-RestMethod -Uri $SNAPSHOT_URL -TimeoutSec 15 -Headers @{ "User-Agent" = "setup-datum/$SETUP_VERSION" } } catch {}
if ($snap -and $snap.file) {
  $haveH = 0
  if ((Test-Path "$NODE\chainstate") -and (Test-Path "$BIN\bitcoin-cli.exe")) { try { $haveH = [int](NodeCli getblockcount) } catch { $haveH = 0 } }
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
Say "  Payout address   $ADDR"; Say "  Block tag        Bitcoin Xor / $NAME"; if ($isXor) { Say "  Pool             Bitcoin Xor at ${POOL_HOST}:$POOL_PORT  (1% fee, you build the templates)" } else { Say ("  Pool             ${POOL_HOST}:$POOL_PORT  key " + $POOL_PUBKEY.Substring(0, 8) + "..." + $POOL_PUBKEY.Substring(120) + "  (that pool's own fee and rules apply)") }
Say "  Install to       $ROOT  (node pruned, ~14 GB, RPC local-only; both programs start with Windows)"
if ($doSnapshot) { Say "  Snapshot         $($snap.file) -> node starts at height $($snap.height)" }
Say "  Firewall         allow TCP $STRATUM_PORT inbound on private networks (your ASICs)"
Say ""
if (-not (ConfirmNo "Install with these settings?")) { Say "Nothing changed."; exit 0 }

# ---------------------------------------------------------------- install
Say ""; Say "Installing..."
foreach ($d in @($ROOT, $BIN, $NODE, $GW, $LOGS, $TMP)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
StopAll

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

# node config (chain data untouched). This file is rewritten on every run; the owner's own relay / block-building policy
# lives in policy.conf, included at the end and never touched again once it exists. The main file beats an included
# one, so a tunable the owner set there is left commented out here.
$curl = "$env:SystemRoot\System32\curl.exe"
$POLICY_CONF = "$NODE\policy.conf"
if (-not (Test-Path $POLICY_CONF)) {
@"
# policy.conf - YOUR node's policy: what it relays, and what goes into the blocks your gateway builds.
# This file is yours; the installer never overwrites it. One option per line, no leading dash.
# Nothing here is required: with nothing set, your node uses the Bitcoin Knots defaults.
# See every option:  "$BIN\bitcoind.exe" -help   (sections "Node relay options" and "Block creation options")
# After a change, run the installer again: it stops the node cleanly and starts it with your policy.
# Guide: https://xorpool.com/datum/policy
#
#blockmintxfee=0.00001      # lowest fee rate (BTC/kvB) a transaction needs to get into YOUR blocks
#minrelaytxfee=0.00001      # lowest fee rate your node relays and keeps in its mempool
#datacarriersize=83         # most bytes of arbitrary data per transaction (0 = none at all)
"@ | Set-Content -Path $POLICY_CONF -Encoding ASCII
}
$policySet = @(Get-Content $POLICY_CONF | ForEach-Object { ($_ -replace '\s*#.*$', '').Trim() } | Where-Object { $_ -match '^-?[a-z0-9]+=' } | ForEach-Object { ($_ -replace '^-', '') -replace '=.*$', '' })
function Tunable($key, $val) { if ($policySet -contains $key) { "#$key=$val   # now set in policy.conf" } else { "$key=$val" } }
@"
# Bitcoin Knots (BLAKE2b fork) - written by setup-datum.ps1 on $(Get-Date -Format yyyy-MM-dd)
# This file is rewritten by the installer. Your own relay / block policy belongs in policy.conf next to it.
server=1
disablewallet=1
prune=2000
txindex=0
$(Tunable "dbcache" $(if ($memMB -ge 7000) { 2000 } else { 600 }))
$(Tunable "maxmempool" 200)
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

# your own policy settings
includeconf=policy.conf
"@ | Set-Content -Path $NODE_CONF -Encoding ASCII
Ok "node config $NODE_CONF"

# gateway config
$cfg = [ordered]@{
  bitcoind = [ordered]@{ rpcurl = "http://127.0.0.1:8332"; rpcuser = "knots"; rpcpassword = $RPC_PASS; work_update_seconds = 40; notify_fallback = $true }
  mining   = [ordered]@{ pool_address = $ADDR; coinbase_tag_primary = $NAME; coinbase_tag_secondary = $NAME }
  stratum  = [ordered]@{ listen_addr = "0.0.0.0"; listen_port = $STRATUM_PORT }
  datum    = [ordered]@{ pool_host = $POOL_HOST; pool_port = $POOL_PORT; pool_pubkey = $POOL_PUBKEY; pool_url = $POOL_URL; pool_pass_full_users = $false; pool_pass_workers = $true; gateway_fee_bps = 0; pooled_mining_only = $true }
  api      = [ordered]@{ listen_addr = "127.0.0.1"; listen_port = 8000; admin_password = $API_PASS; miner_listen_addr = "127.0.0.1"; miner_listen_port = 8001 }   # the miner-lookup API defaults to :8000 too and logs "Address in use"
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
function NodeCli { & "$BIN\bitcoin-cli.exe" "-datadir=$NODE" "-conf=$NODE\bitcoin.conf" @args 2>$null }   # not "cli": that is a built-in alias of Clear-Item and aliases win
$n = (Get-Process bitcoind -ErrorAction SilentlyContinue) -ne $null; $g = (Get-Process ratum-gateway -ErrorAction SilentlyContinue) -ne $null
Write-Host ("node:     " + $(if ($n) {"running"} else {"NOT running"}) + "    gateway: " + $(if ($g) {"running"} else {"NOT running"}))
try { $i = NodeCli getblockchaininfo | ConvertFrom-Json; $p = [math]::Round($i.verificationprogress*100,2)
  if ($p -gt 99.99) { Write-Host "chain:    height $($i.blocks)  at tip" } else { Write-Host "chain:    height $($i.blocks)  syncing $p%" }
  Write-Host "peers:    $(NodeCli getconnectioncount)" } catch { Write-Host "chain:    node starting / not answering RPC yet" }
# live smoothed estimate (needs the API password from the gateway config), else the mean of the last five COMPLETED minutes;
# never the newest history point, which is the minute still in progress and made a small rig read 0.00 half the time
try { $hdr = @{}; try { $gp = (Get-Content "C:\XorDatum\gateway\gateway.json" -Raw | ConvertFrom-Json).api.admin_password; if ($gp) { $hdr = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$gp")) } } } catch {}
  $s = Invoke-RestMethod http://127.0.0.1:8000/stats.json -TimeoutSec 3 -Headers $hdr
  $ths = 0.0; if ($s.stratum -and $s.stratum.hashrate_ths -gt 0) { $ths = [double]$s.stratum.hashrate_ths }
  else { $hist = @($s.hashrate.history | ForEach-Object { $_[1] }); if ($hist.Count -gt 1) { $from = [Math]::Max(0, $hist.Count - 6); $doneMin = $hist[$from..($hist.Count - 2)]; $ths = (($doneMin | Measure-Object -Average).Average) / 1e12 } }
  Write-Host ("gateway:  {0:N2} TH/s   shares accepted {1}   rejected {2}" -f $ths, $s.shares_accepted.count, $s.shares_rejected.count) } catch { Write-Host "gateway:  waiting for the node / not answering yet" }
Write-Host "log:      C:\XorDatum\logs\gateway.log   node: C:\XorDatum\node\debug.log"
'@ | Set-Content -Path "$ROOT\datum-status.ps1" -Encoding ASCII

$logMark = if (Test-Path "$LOGS\gateway.log") { (Get-Item "$LOGS\gateway.log").Length } else { 0 }   # only what the gateway logs from here on counts for the pool-link check
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
  StopAll
  Remove-Item "$NODE\blocks", "$NODE\chainstate" -Recurse -Force -ErrorAction SilentlyContinue
  $tar = "$env:SystemRoot\System32\tar.exe"
  & $tar -xf $f -C $NODE
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$NODE\chainstate")) { Die "could not extract the snapshot (this Windows tar may lack zstd support). Re-run the script and answer n to the snapshot; the node will sync from scratch." }
  Remove-Item $f -Force
  Start-ScheduledTask -TaskName "XorDatum Node"; Start-Sleep 3; Start-ScheduledTask -TaskName "XorDatum Gateway"
  $got = ""; for ($i = 0; $i -lt 90; $i++) { try { $got = (NodeCli getblockhash "$($snap.height)"); if ($got) { break } } catch {}; Start-Sleep 2 }
  if ($got -and $got.Trim() -eq $snap.block_hash) { Ok "node started from the snapshot at height $($snap.height); block hash verified" }
  else { Warn "could not verify block $($snap.height) against the published hash yet (node still starting?) - check later with datum-status" }
}
Remove-Item "$TMP\*" -Recurse -Force -ErrorAction SilentlyContinue

# Did the pool accept us? The gateway authenticates the pool by its public key on every connection, so a wrong host,
# port or key shows up here as a link that never comes up. Checked for every pool, typed by hand or not.
$link = ""
for ($i = 0; $i -lt 20; $i++) {
  try { $link = "" + (Invoke-RestMethod http://127.0.0.1:8000/stats.json -TimeoutSec 3).status } catch { $link = "" }
  if ($link -eq "Connected and Ready") { break }; Start-Sleep 2
}
$newLog = ""
try { $fs = [System.IO.File]::Open("$LOGS\gateway.log", 'Open', 'Read', 'ReadWrite'); [void]$fs.Seek([Math]::Min($logMark, $fs.Length), 'Begin'); $sr = New-Object System.IO.StreamReader($fs); $newLog = $sr.ReadToEnd(); $sr.Close(); $fs.Close() } catch {}
if ($link -eq "Connected and Ready") { Ok "pool link up: ${POOL_HOST}:$POOL_PORT answered and proved its key" }
elseif ($newLog -match 'DATUM connection ended|DATUM pool is unreachable') {
  Warn "the gateway cannot complete the handshake with ${POOL_HOST}:$POOL_PORT. Either that host:port is not a DATUM pool,"
  Say  "         it is unreachable from here, or the public key is not that pool's key. Nothing will be mined until it connects."
  Say  "         Check the three values with the pool, then run this script again. (gateway log: $LOGS\gateway.log)"
} else { Say ("  gateway status: " + $(if ($link) { $link } else { "not answering yet" }) + " - normal while the node is still syncing; datum-status shows the pool link later") }

# the address on the interface that carries the default route (the real LAN), not a Hyper-V / WSL / VPN adapter
$myip = $null
try { $ifi = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction Stop | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1).InterfaceIndex
      $myip = (Get-NetIPAddress -InterfaceIndex $ifi -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1).IPAddress } catch {}
if (-not $myip) { $myip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress }
Say ""; Write-Host "Done." -ForegroundColor Green; Say ""
Say "  Point your ASICs at:   stratum+tcp://$($myip):$STRATUM_PORT"
Say "                         worker:  anything.rig1   password:  x"; Say ""
if ($doSnapshot) { Say "  The node started from the snapshot and is catching up the last few blocks - your ASICs get work within minutes." }
elseif ($hadChain) { Say "  The node restarted with its existing chain data and is catching up whatever it missed - your ASICs get work within minutes." }
else { Say "  The node is now syncing the chain from the start - 1 to 3 days on a small PC. Your ASICs get work automatically"; Say "  the moment it reaches the tip; until then the gateway waits. Leave the PC on (and not sleeping)." }
Say ""; Say "  Check on it any time (PowerShell):  powershell -ExecutionPolicy Bypass -File $ROOT\datum-status.ps1"
if ($isXor) { Say "  Your stats once shares flow:        $XOR_URL/miner/$ADDR" } elseif ($POOL_URL) { Say "  Your stats are on your pool's own site:  $POOL_URL" }
Say "  Both programs start with Windows automatically. Power settings: make sure the PC does not sleep."
Say ""
& powershell -ExecutionPolicy Bypass -File "$ROOT\datum-status.ps1"
