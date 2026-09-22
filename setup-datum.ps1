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
  Already running Bitcoin Knots on this PC (the wallet program)? The script notices it and offers to install only the
  gateway, using that node: two lines go into its bitcoin.conf (RPC on, block notify), nothing else changes.

  Usage:  right-click PowerShell -> Run as administrator, then:
          powershell -ExecutionPolicy Bypass -File setup-datum.ps1
          add  -ExistingNode "C:\path\to\Bitcoin"  to name the data folder of a node the script did not find by itself
  Source: https://github.com/bitcoinxor/datum-in-a-box   Questions: https://t.me/bitcoinxor
#>
param([string]$ExistingNode = "")
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SETUP_VERSION = "v1.7.3"
$KNOTS_VER  = "29.4.2.knots20260508"
$RATUM_VER  = "0.1.28"
# The checksums of the two official Windows builds, taken from the projects' own SHA256SUMS / .sha256 files on GitHub and
# pinned here, so a download from anywhere (GitHub, or our mirror when GitHub is unreachable) is checked against the
# authors' values, not against whatever sits next to the file. Update both when bumping a version.
$KNOTS_SHA256 = "8fa3445a0f3ecc7d1f9e4f4778e44c786883437ac781902a38135be5ea0a892b"   # bitcoin-29.4.2.knots20260508-win64-pgpverifiable.zip
$RATUM_SHA256 = "0ccbbbfb2bec452243d72a04f61e8a931a316e3e720ebd3f228d313ee5cef63a"   # ratum-gateway-0.1.28-x86_64-windows.zip
$MIRROR = "https://snapshot.xorpool.com/mirror"   # same files, for networks where GitHub's release downloads fail (China)
$VCREDIST_URL = "https://aka.ms/vs/17/release/vc_redist.x64.exe"   # the gateway needs Microsoft's VC++ runtime (vcruntime140.dll); a bare Windows 10 lacks it
# Everything the gateway (and datum-status) asks the node for. With an owner's own Bitcoin Knots the gateway's RPC login is limited to
# exactly these, so it can never reach the wallet calls (rpcwhitelist). Union of ratum-gateway 0.1.28's calls + the status script's.
$GW_RPC_ALLOW = "getblocktemplate,submitblock,getblock,getbestblockhash,getblockhash,getblockchaininfo,getblockcount,getnetworkinfo,getmininginfo,getmempoolinfo,getconnectioncount,waitforblockheight,preciousblock,uptime"
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
  try { Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -Headers @{ "User-Agent" = "setup-datum/$SETUP_VERSION" }; return }
  catch { $first = $_.Exception.Message }
  if ($url -like "https://github.com/*" -or $url -like "https://raw.githubusercontent.com/*") {   # GitHub often fails from China: same file from our mirror (binaries keep their pinned checksum)
    $alt = "$MIRROR/" + ($url.Split('/')[-1]); Warn "GitHub download failed ($first); trying the mirror $alt"
    try { Invoke-WebRequest -Uri $alt -OutFile $out -UseBasicParsing -Headers @{ "User-Agent" = "setup-datum/$SETUP_VERSION" }; return } catch { $first = $_.Exception.Message }
  }
  Die "download failed: $url ($first)"
}
function TaskExists($n) { return [bool](Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) }
function StopTask($n) { if (TaskExists $n) { Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue } }
function NodeCli { & "$BIN\bitcoin-cli.exe" "-datadir=$NODE" "-conf=$NODE_CONF" @args 2>$null }   # automatic $args - a declared ($args) parameter swallows the arguments and the call returns nothing
function StopGateway { StopTask "XorDatum Gateway"; Get-Process ratum-gateway -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
function StopAll {
  # gateway first (stateless), then ask the node to shut down and WAIT: Stop-ScheduledTask kills the process outright,
  # and a killed node has not flushed its chainstate - next start it rewinds to the last flush and replays (minutes to hours)
  StopGateway
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

# ---------------------------------------------------------------- a Bitcoin Knots that is already on this PC?
# The wallet program (bitcoin-qt) or a bitcoind that is not ours. Found by its running process (data folder from -datadir=
# or the owner's AppData), by the marker a previous run left, or by -ExistingNode. If found, the owner may keep it and
# install only the gateway: the gateway then logs in to that node with its cookie file, no password is written anywhere.
$EXT = $false; $EXT_DIR = ""; $EXT_EXE = ""; $extRunning = $false
$EXT_MARK = "$ROOT\existing-node.txt"
function OtherNodeProcs { @(Get-CimInstance Win32_Process -Filter "Name='bitcoin-qt.exe' OR Name='bitcoind.exe'" | Where-Object { -not ($_.ExecutablePath -like "$BIN\*") }) }
$procs = OtherNodeProcs
foreach ($pr in $procs) {
  $extRunning = $true; if ($pr.ExecutablePath) { $EXT_EXE = $pr.ExecutablePath }
  if ($pr.CommandLine -match '-datadir=(?:"([^"]+)"|(\S+))') { $d = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }; if (-not $EXT_DIR) { $EXT_DIR = $d } }
  elseif (-not $EXT_DIR) {
    try { $sid = (Invoke-CimMethod -InputObject $pr -MethodName GetOwnerSid).Sid
          $prof = (Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Select-Object -First 1).LocalPath
          if ($prof -and (Test-Path "$prof\AppData\Roaming\Bitcoin")) { $EXT_DIR = "$prof\AppData\Roaming\Bitcoin" } } catch {}
  }
}
# The wallet program remembers the data folder chosen at its first start in the registry (Qt settings), not on its command
# line: HKCU\Software\Bitcoin\Bitcoin-Qt\strDataDir, with forward slashes. Ours (this elevated user) and every loaded user hive.
function RegDataDirs($extra) {
  $paths = @("HKCU:\Software\Bitcoin\Bitcoin-Qt") + @($extra)
  try { if (-not (Get-PSDrive HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Global | Out-Null }
        $paths += @(Get-ChildItem HKU:\ -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { "HKU:\$($_.PSChildName)\Software\Bitcoin\Bitcoin-Qt" }) } catch {}
  foreach ($rp in $paths) {
    try { $v = "" + (Get-ItemProperty -Path $rp -Name strDataDir -ErrorAction Stop).strDataDir } catch { continue }
    if ($v) { $v = ($v -replace '/', '\').TrimEnd('\'); if (Test-Path "$v\chainstate") { return $v } }
  }
  return ""
}
if (-not $EXT_DIR) { $EXT_DIR = RegDataDirs @() }
if ($ExistingNode) { $EXT_DIR = $ExistingNode.Trim().TrimEnd('\') }
elseif (-not $EXT_DIR -and (Test-Path $EXT_MARK)) { $EXT_DIR = (Get-Content $EXT_MARK -First 1).Trim() }
elseif (-not $EXT_DIR -and (Test-Path "$env:APPDATA\Bitcoin\chainstate")) { $EXT_DIR = "$env:APPDATA\Bitcoin" }
if (-not $EXT_EXE) { foreach ($c in @("$env:ProgramFiles\Bitcoin\bitcoin-qt.exe", "$env:ProgramFiles\Bitcoin Knots\bitcoin-qt.exe")) { if (Test-Path $c) { $EXT_EXE = $c; break } } }
if ($ExistingNode -and -not (Test-Path "$EXT_DIR\chainstate")) { Die "-ExistingNode ${EXT_DIR}: no 'chainstate' folder there, so it is not a node's data folder (the default is %APPDATA%\Bitcoin)" }
if ($EXT_DIR -and (Test-Path "$EXT_DIR\chainstate")) {
  Say ""; Say ("Bitcoin Knots is already on this PC: data folder $EXT_DIR" + $(if ($extRunning) { "  (running now)" } else { "" }))
  Say "     1) Use it: install only the DATUM gateway, no second node   (the default)"
  Say "     2) Install a separate node under $ROOT as well   (two nodes cannot run at the same time: same ports)"
  while ($true) {
    $c = Ask "   Node" $(if (Test-Path $NODE_CONF) { "2" } else { "1" })
    if ($c -eq "1") { $EXT = $true; break } elseif ($c -eq "2") { break }
    Write-Host "   Type 1 or 2." -ForegroundColor Red
  }
  if ($EXT) {
    while ($true) {
      $EXT_DIR = (Ask "   Its data folder (the one with 'blocks' and 'chainstate' in it)" $EXT_DIR).TrimEnd('\')
      if (Test-Path "$EXT_DIR\chainstate") { Ok "node: your Bitcoin Knots at $EXT_DIR"; break }
      Write-Host "   No 'chainstate' folder in $EXT_DIR - not a node's data folder. In Bitcoin Knots: Settings > Options > Main shows the data directory." -ForegroundColor Red
    }
  }
}
elseif ($EXT_EXE -or $extRunning) { Say ""; Warn "Bitcoin Knots seems to be on this PC ($(if ($EXT_EXE) { $EXT_EXE } else { 'running' })) but its data folder was not found. To use it instead of installing a node,"; Say "         stop here (Ctrl+C) and run again with  -ExistingNode `"<its data folder>`"  (Bitcoin Knots: Help > Debug window > Information > Datadir)" }
if ($EXT) { $MIN_DISK_GB = 1 }   # the gateway is 3 MB
elseif (Test-Path "$NODE\chainstate") { $MIN_DISK_GB = 5 }   # the node already holds its ~14 GB; an update only needs working room
if ($freeGB -lt $MIN_DISK_GB) { Die "need at least $MIN_DISK_GB GB free on $($ROOT.Substring(0,2)) (have $freeGB GB). The pruned node uses ~14 GB plus headroom." }
if ($memMB -lt 3500) { Warn "less than 4 GB RAM - it works, but the first sync will be slow; Windows manages swap on its own" }
$UPDATE = (Test-Path $NODE_CONF) -or (Test-Path $GW_CONF)
$hadChain = Test-Path "$NODE\chainstate"   # chain data from an earlier run - decides the wording at the end
if ($UPDATE) { Say ""; Say ("An existing install was found in $ROOT. It will be updated in place: binaries refreshed, configs rewritten from your answers" + $(if ($EXT) { "." } else { ", chain data kept." })) }

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

$doSnapshot = $false; $snap = $null; $autoStart = $false
if ($EXT) {
  Say ""; Say "4) Mining happens only while Bitcoin Knots is running. The gateway starts with Windows and waits for it."
  if ($EXT_EXE) { $autoStart = ConfirmYes "   Start Bitcoin Knots automatically when you log in to Windows (a shortcut in your Startup folder)?" }
  else { Say "   (bitcoin-qt.exe was not found in the usual place, so no autostart shortcut is offered - start it as you do today)" }
}
try { $snap = Invoke-RestMethod -Uri $SNAPSHOT_URL -TimeoutSec 15 -Headers @{ "User-Agent" = "setup-datum/$SETUP_VERSION" } } catch {}
if ($snap -and $snap.file -and -not $EXT) {
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
if ($EXT) {
  Say "  Node             your Bitcoin Knots at $EXT_DIR  (two lines go into its bitcoin.conf: server=1, blocknotify; login by its cookie file)"
  Say "  Install to       $ROOT  (gateway only; starts with Windows and waits for Bitcoin Knots)"
  if ($autoStart) { Say "  Autostart        Bitcoin Knots shortcut in your Startup folder" }
} else { Say "  Install to       $ROOT  (node pruned, ~14 GB, RPC local-only; both programs start with Windows)" }
if ($doSnapshot) { Say "  Snapshot         $($snap.file) -> node starts at height $($snap.height)" }
Say "  Firewall         allow TCP $STRATUM_PORT inbound on private networks (your ASICs)"
Say ""
if (-not (ConfirmNo "Install with these settings?")) { Say "Nothing changed."; exit 0 }
New-Item -ItemType Directory -Force -Path $GW | Out-Null; $cfg0 = [ordered]@{ mining = [ordered]@{ pool_address = $ADDR; coinbase_tag_primary = $NAME; coinbase_tag_secondary = $NAME }
  datum = [ordered]@{ pool_host = $POOL_HOST; pool_port = $POOL_PORT; pool_pubkey = $POOL_PUBKEY; pool_url = $POOL_URL }; api = [ordered]@{ admin_password = $API_PASS } }
if (-not (Test-Path $GW_CONF)) { $cfg0 | ConvertTo-Json -Depth 4 | Set-Content -Path $GW_CONF -Encoding ASCII }   # answers on disk before any download: a re-run offers them as defaults

# ---------------------------------------------------------------- install
Say ""; Say "Installing..."
foreach ($d in @($ROOT, $BIN, $GW, $LOGS, $TMP) + $(if ($EXT) { @() } else { @($NODE) })) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
if ($EXT) {
  StopGateway   # never the node: it is not ours
  if (TaskExists "XorDatum Node") { StopAll; Disable-ScheduledTask -TaskName "XorDatum Node" | Out-Null; Warn "the node this script installed earlier under $NODE is stopped and disabled; your Bitcoin Knots is the node now" }
  Set-Content -Path $EXT_MARK -Value $EXT_DIR -Encoding ASCII
} else { StopAll; Remove-Item $EXT_MARK -Force -ErrorAction SilentlyContinue }

# Knots
$curKnots = ""; if (Test-Path "$BIN\bitcoind.exe") { try { $curKnots = (& "$BIN\bitcoind.exe" --version | Select-Object -First 1) } catch {} }
if ($EXT) { }
elseif ($curKnots -match [regex]::Escape("v$KNOTS_VER")) { Ok "Bitcoin Knots v$KNOTS_VER already installed" }
else {
  Say "downloading Bitcoin Knots v$KNOTS_VER (~50 MB)..."
  $kzip = "bitcoin-$KNOTS_VER-win64-pgpverifiable.zip"; $kurl = "https://github.com/bitcoinknots/bitcoin/releases/download/v$KNOTS_VER"
  Download "$kurl/$kzip" "$TMP\$kzip"
  if ((Get-Sha256 "$TMP\$kzip") -ne $KNOTS_SHA256) { Remove-Item "$TMP\$kzip" -Force; Die "checksum MISMATCH on $kzip - not installing it" }
  Expand-Archive -Path "$TMP\$kzip" -DestinationPath "$TMP\knots" -Force
  $src = Get-ChildItem "$TMP\knots" -Recurse -Filter bitcoind.exe | Select-Object -First 1
  Copy-Item $src.FullName "$BIN\bitcoind.exe" -Force; Copy-Item (Join-Path $src.DirectoryName "bitcoin-cli.exe") "$BIN\bitcoin-cli.exe" -Force
  Ok ((& "$BIN\bitcoind.exe" --version | Select-Object -First 1))
}
# ratum. First the Microsoft VC++ runtime it is linked against: without vcruntime140.dll the exe exits at once, printing nothing
# (seen on a bare Windows 10). The runtime installer comes from Microsoft and is checked for Microsoft's Authenticode signature.
if (-not (Test-Path "$env:SystemRoot\System32\vcruntime140.dll")) {
  Say "installing the Microsoft Visual C++ runtime (the gateway needs it; ~25 MB from Microsoft)..."
  $vcr = "$TMP\vc_redist.x64.exe"; Download $VCREDIST_URL $vcr
  $sig = Get-AuthenticodeSignature $vcr
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { Remove-Item $vcr -Force; Die "the VC++ runtime installer is not signed by Microsoft - not running it" }
  $pr = Start-Process $vcr -ArgumentList "/install /quiet /norestart" -Wait -PassThru
  if (-not (Test-Path "$env:SystemRoot\System32\vcruntime140.dll")) { Die "the VC++ runtime did not install (exit code $($pr.ExitCode)). Install it by hand from $VCREDIST_URL and run this script again." }
  Ok "Microsoft Visual C++ runtime installed"
}
$curRatum = ""; if (Test-Path "$BIN\ratum-gateway.exe") { try { $curRatum = (& "$BIN\ratum-gateway.exe" --version 2>&1 | Select-Object -First 1) } catch {} }
if ($curRatum -match " $RATUM_VER ") { Ok "ratum-gateway $RATUM_VER already installed" }
else {
  Say "downloading ratum-gateway $RATUM_VER (~3 MB)..."
  $rzip = "ratum-gateway-$RATUM_VER-x86_64-windows.zip"; $rurl = "https://github.com/iohzrd/ratum/releases/download/v$RATUM_VER"
  Download "$rurl/$rzip" "$TMP\$rzip"
  if ((Get-Sha256 "$TMP\$rzip") -ne $RATUM_SHA256) { Remove-Item "$TMP\$rzip" -Force; Die "checksum MISMATCH on $rzip - not installing it" }
  Expand-Archive -Path "$TMP\$rzip" -DestinationPath "$TMP\ratum" -Force
  $src = Get-ChildItem "$TMP\ratum" -Recurse -Filter ratum-gateway.exe | Select-Object -First 1
  if (-not $src) { Die "ratum-gateway.exe not found in the archive" }
  Copy-Item $src.FullName "$BIN\ratum-gateway.exe" -Force
  $v = ""; try { $v = "" + (& "$BIN\ratum-gateway.exe" --version 2>&1 | Select-Object -First 1) } catch {}
  if ($v -notmatch [regex]::Escape($RATUM_VER)) { Die "ratum-gateway.exe does not run on this PC (exit code $LASTEXITCODE, output: '$v'). An antivirus may be blocking it; look for a quarantine entry for C:\XorDatum\bin\ratum-gateway.exe, restore it and add an exclusion, then run this script again." }
  Ok $v
}

# node config (chain data untouched). This file is rewritten on every run; the owner's own relay / block-building policy
# lives in policy.conf, included at the end and never touched again once it exists. The main file beats an included
# one, so a tunable the owner set there is left commented out here.
$curl = "$env:SystemRoot\System32\curl.exe"
$NOTIFY_CMD = "$curl -s -m 3 http://127.0.0.1:8000/NOTIFY"
$rpcPort = 8332; $extUser = ""; $extPass = ""
if ($EXT) {
  # The owner's bitcoin.conf is theirs: read it, keep it byte for byte, comment out only 'server=' and 'blocknotify=' lines and put
  # ours at the top (top of file = every network section). Login is by the node's cookie file unless the file sets a password
  # (a node with rpcpassword writes no cookie). The wallet program must be closed while its config changes - and it must
  # restart anyway to switch RPC on.
  while (OtherNodeProcs) { Read-Host "  Please close Bitcoin Knots now (File > Exit, wait until the window is gone), then press Enter" | Out-Null }
  $EXT_CONF = "$EXT_DIR\bitcoin.conf"; $raw = [byte[]]@(); $enc = New-Object System.Text.UTF8Encoding($false)
  if (Test-Path $EXT_CONF) {
    Copy-Item $EXT_CONF "$EXT_CONF.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
    $raw = [IO.File]::ReadAllBytes($EXT_CONF)
    if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { $enc = New-Object System.Text.UTF8Encoding($true) }
    else { try { [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($raw) } catch { $enc = [System.Text.Encoding]::Default } }   # not UTF-8: the system code page (GBK etc.)
  }
  $text = if ($raw.Length) { $enc.GetString($raw) } else { "" }
  if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }   # not StartsWith: culture-aware, it treats U+FEFF as ignorable and matches anything
  $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
  $hadNotify = ""; $out = New-Object System.Collections.Generic.List[string]
  foreach ($l in ($text -split "`r?`n")) {
    $t = ($l -replace '#.*$', '').Trim()
    if ($t -match '^rpcuser=(.*)$') { $extUser = $Matches[1].Trim() }
    elseif ($t -match '^rpcpassword=(.*)$') { $extPass = $Matches[1].Trim() }
    elseif ($t -match '^rpcport=(\d+)$') { $rpcPort = [int]$Matches[1] }
    if ($t -match '^server=' -or $t -match '^blocknotify=' -or $t -match '^rpcwhitelistdefault=' -or $t -match '^rpcwhitelist=(__cookie__|[^:]*):.*getblocktemplate') { if ($t -match '^blocknotify=(.*)$') { $hadNotify = $Matches[1] }; $out.Add("#$l   # replaced by setup-datum.ps1, see the top of this file") } else { $out.Add($l) }
  }
  $gwUser = if ($extPass) { $extUser } else { "__cookie__" }   # the name the gateway logs in with: cookie logins are always __cookie__
  $ours = @("# --- added by setup-datum.ps1 on $(Get-Date -Format yyyy-MM-dd): RPC on for the DATUM gateway on this PC (local only), tell it about new blocks,",
            "# and limit the gateway's login to the block-building calls it needs (never the wallet). Other RPC users are unaffected.",
            "server=1", "blocknotify=$NOTIFY_CMD", "rpcwhitelist=${gwUser}:$GW_RPC_ALLOW", "rpcwhitelistdefault=0", "")
  [IO.File]::WriteAllBytes($EXT_CONF, $enc.GetBytes((($ours + $out) -join $nl)))
  if ($hadNotify) { Warn "your bitcoin.conf had its own blocknotify ($hadNotify); it is commented out - the gateway needs this one" }
  if ($extUser -and -not $extPass) { Die "$EXT_CONF sets rpcuser without rpcpassword; add the password line or remove rpcuser (then the cookie file is used)" }
  Ok ("node config ${EXT_CONF}: server=1 + blocknotify + rpcwhitelist added, login by " + $(if ($extPass) { "rpcuser/rpcpassword from the file" } else { "cookie file" }) + ", RPC port $rpcPort")
}
$POLICY_CONF = "$NODE\policy.conf"
if ($EXT) { }
elseif (-not (Test-Path $POLICY_CONF)) {
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
$policySet = @(); if (-not $EXT) { $policySet = @(Get-Content $POLICY_CONF | ForEach-Object { ($_ -replace '\s*#.*$', '').Trim() } | Where-Object { $_ -match '^-?[a-z0-9]+=' } | ForEach-Object { ($_ -replace '^-', '') -replace '=.*$', '' }) }
function Tunable($key, $val) { if ($policySet -contains $key) { "#$key=$val   # now set in policy.conf" } else { "$key=$val" } }
if (-not $EXT) {
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
blocknotify=$NOTIFY_CMD

# your own policy settings
includeconf=policy.conf
"@ | Set-Content -Path $NODE_CONF -Encoding ASCII
Ok "node config $NODE_CONF"
}

# gateway config. Written twice: right after the confirm, so a re-run offers these answers as defaults even if a download
# fails a moment later, and again at the end once the node login details are known.
function WriteGatewayConfig {
  $cfg = [ordered]@{
    bitcoind = $(if (-not $EXT) { [ordered]@{ rpcurl = "http://127.0.0.1:8332"; rpcuser = "knots"; rpcpassword = $RPC_PASS; work_update_seconds = 40; notify_fallback = $true } }
                elseif ($extPass) { [ordered]@{ rpcurl = "http://127.0.0.1:$rpcPort"; rpcuser = $extUser; rpcpassword = $extPass; work_update_seconds = 40; notify_fallback = $true } }
                else { [ordered]@{ rpcurl = "http://127.0.0.1:$rpcPort"; rpccookiefile = "$EXT_DIR\.cookie"; work_update_seconds = 40; notify_fallback = $true } })
    mining   = [ordered]@{ pool_address = $ADDR; coinbase_tag_primary = $NAME; coinbase_tag_secondary = $NAME }
    stratum  = [ordered]@{ listen_addr = "0.0.0.0"; listen_port = $STRATUM_PORT }
    datum    = [ordered]@{ pool_host = $POOL_HOST; pool_port = $POOL_PORT; pool_pubkey = $POOL_PUBKEY; pool_url = $POOL_URL; pool_pass_full_users = $false; pool_pass_workers = $true; gateway_fee_bps = 0; pooled_mining_only = $true }
    api      = [ordered]@{ listen_addr = "127.0.0.1"; listen_port = 8000; admin_password = $API_PASS; miner_listen_addr = "127.0.0.1"; miner_listen_port = 8001 }   # the miner-lookup API defaults to :8000 too and logs "Address in use"
  }
  $cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $GW_CONF -Encoding ASCII
  Ok "gateway config $GW_CONF"
}
WriteGatewayConfig

# scheduled tasks: start with Windows as SYSTEM, restart if they die; gateway output to a log file
$sysPrincipal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
$trig = New-ScheduledTaskTrigger -AtStartup
if ($EXT) {
  # The gateway exits when the node is not there (no cookie file yet, wallet program closed), so it runs inside a loop that
  # starts it again every 30 s - the task's own restart-on-failure gives up after 999 tries, a loop never does.
  @"
@echo off
:loop
echo [%date% %time%] gateway-loop: starting ratum-gateway >> "$LOGS\gateway.log"
"$BIN\ratum-gateway.exe" -c "$GW_CONF" >> "$LOGS\gateway.log" 2>&1
echo [%date% %time%] gateway-loop: ratum-gateway exited with code %errorlevel% - starting again in 30 s >> "$LOGS\gateway.log"
ping -n 31 127.0.0.1 >nul
goto loop
"@ | Set-Content -Path "$BIN\gateway-loop.cmd" -Encoding ASCII
  $gwAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"`"$BIN\gateway-loop.cmd`"`""
  Register-ScheduledTask -TaskName "XorDatum Gateway" -Action $gwAction -Trigger $trig -Principal $sysPrincipal -Settings $settings -Force | Out-Null
  Ok "scheduled task (starts with Windows, waits for Bitcoin Knots)"
} else {
  $nodeAction = New-ScheduledTaskAction -Execute "$BIN\bitcoind.exe" -Argument "-datadir=$NODE -conf=$NODE_CONF"
  $gwAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument "/c `"`"$BIN\ratum-gateway.exe`" -c `"$GW_CONF`" >> `"$LOGS\gateway.log`" 2>&1`""
  Register-ScheduledTask -TaskName "XorDatum Node" -Action $nodeAction -Trigger $trig -Principal $sysPrincipal -Settings $settings -Force | Out-Null
  Register-ScheduledTask -TaskName "XorDatum Gateway" -Action $gwAction -Trigger $trig -Principal $sysPrincipal -Settings $settings -Force | Out-Null
  Ok "scheduled tasks (start with Windows)"
}
if ($autoStart) {
  try { $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) "Bitcoin Knots.lnk"; $sh = New-Object -ComObject WScript.Shell; $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = $EXT_EXE; $sc.Arguments = "-min"; $sc.WorkingDirectory = Split-Path $EXT_EXE; $sc.Save(); Ok "autostart shortcut $lnk (starts minimized)" }
  catch { Warn "could not create the Startup shortcut ($($_.Exception.Message)) - start Bitcoin Knots by hand after a reboot" }
}

# firewall: the gateway port, private/domain networks only (your ASICs); the node's RPC stays local
if (-not (Get-NetFirewallRule -DisplayName "XorDatum gateway $STRATUM_PORT" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "XorDatum gateway $STRATUM_PORT" -Direction Inbound -Protocol TCP -LocalPort $STRATUM_PORT -Profile Private, Domain -Action Allow | Out-Null
}
Ok "firewall rule for port $STRATUM_PORT (private networks)"

# status helper
@'
$ROOT = if ($env:XORDATUM_ROOT) { $env:XORDATUM_ROOT } else { "C:\XorDatum" }
$ext = Test-Path "$ROOT\existing-node.txt"   # the node is the owner's own Bitcoin Knots (wallet program), not one this script runs
# node RPC straight over HTTP with the login the gateway uses (gateway.json): cookie file or user/password
$gwc = $null; try { $gwc = Get-Content "$ROOT\gateway\gateway.json" -Raw | ConvertFrom-Json } catch {}
function NodeRpc($method) {
  $b = $gwc.bitcoind; $cred = if ($b.rpcuser) { "$($b.rpcuser):$($b.rpcpassword)" } else { (Get-Content $b.rpccookiefile -Raw).Trim() }
  $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cred)) }
  (Invoke-RestMethod -Uri $b.rpcurl -Method Post -Headers $h -ContentType 'application/json' -Body ('{"jsonrpc":"1.0","id":"s","method":"' + $method + '","params":[]}') -TimeoutSec 5).result
}
$n = (Get-Process bitcoind, bitcoin-qt -ErrorAction SilentlyContinue) -ne $null; $g = (Get-Process ratum-gateway -ErrorAction SilentlyContinue) -ne $null
Write-Host ("node:     " + $(if ($n) {"running"} else { if ($ext) {"NOT running - start Bitcoin Knots"} else {"NOT running"} }) + "    gateway: " + $(if ($g) {"running"} else { if ($ext -and -not $n) {"waiting for the node"} else {"NOT running"} }))
try { $i = NodeRpc getblockchaininfo; $p = [math]::Round($i.verificationprogress*100,2)
  if ($p -gt 99.99) { Write-Host "chain:    height $($i.blocks)  at tip" } else { Write-Host "chain:    height $($i.blocks)  syncing $p%" }
  Write-Host "peers:    $(NodeRpc getconnectioncount)   version: $((NodeRpc getnetworkinfo).subversion)" } catch { Write-Host "chain:    node starting / not answering RPC yet" }
# live smoothed estimate (needs the API password from the gateway config), else the mean of the last five COMPLETED minutes;
# never the newest history point, which is the minute still in progress and made a small rig read 0.00 half the time
try { $hdr = @{}; try { $gp = $gwc.api.admin_password; if ($gp) { $hdr = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$gp")) } } } catch {}
  $s = Invoke-RestMethod http://127.0.0.1:8000/stats.json -TimeoutSec 3 -Headers $hdr
  $ths = 0.0; if ($s.stratum -and $s.stratum.hashrate_ths -gt 0) { $ths = [double]$s.stratum.hashrate_ths }
  else { $hist = @($s.hashrate.history | ForEach-Object { $_[1] }); if ($hist.Count -gt 1) { $from = [Math]::Max(0, $hist.Count - 6); $doneMin = $hist[$from..($hist.Count - 2)]; $ths = (($doneMin | Measure-Object -Average).Average) / 1e12 } }
  Write-Host ("gateway:  {0:N2} TH/s   shares accepted {1}   rejected {2}" -f $ths, $s.shares_accepted.count, $s.shares_rejected.count) } catch { Write-Host "gateway:  waiting for the node / not answering yet" }
Write-Host ("log:      $ROOT\logs\gateway.log" + $(if ($ext) { "" } else { "   node: $ROOT\node\debug.log" }))
'@ | Set-Content -Path "$ROOT\datum-status.ps1" -Encoding ASCII

# datum-pool.ps1: change the pool later with one question, no need to run the installer again (fetched from the same release; not fatal if it fails)
$helperOk = $false
foreach ($hu in @("https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/$SETUP_VERSION/datum-pool.ps1", "$MIRROR/datum-pool.ps1")) {
  try { Invoke-WebRequest -Uri $hu -OutFile "$ROOT\datum-pool.ps1" -UseBasicParsing -Headers @{ "User-Agent" = "setup-datum/$SETUP_VERSION" }; $helperOk = $true; break } catch {}
}
if ($helperOk) { Ok "helper $ROOT\datum-pool.ps1 (change pool)" } else { Warn "could not fetch datum-pool.ps1 (the change-pool helper); get it later from github.com/bitcoinxor/datum-in-a-box" }

$logMark = if (Test-Path "$LOGS\gateway.log") { (Get-Item "$LOGS\gateway.log").Length } else { 0 }   # only what the gateway logs from here on counts for the pool-link check
$extVersion = ""
if ($EXT) {
  Start-ScheduledTask -TaskName "XorDatum Gateway"; Start-Sleep 2
  if ((Get-ScheduledTask -TaskName "XorDatum Gateway").State -ne 'Running') { Die "the gateway task did not start - see $LOGS\gateway.log" }
  Say ""; Say "Now start Bitcoin Knots again (your usual shortcut). The gateway is running and waits for it."
  Read-Host "  Press Enter once the Bitcoin Knots window is open" | Out-Null
  # its RPC comes up a little after the window; read the version through the gateway's own login to prove that login works
  $ni = $null; $gwc = Get-Content $GW_CONF -Raw | ConvertFrom-Json
  function ExtRpc($method, $params) {   # JSON-RPC with the login from gateway.json (cookie file or user/password)
    $b = $gwc.bitcoind; $cred = if ($b.rpcuser) { "$($b.rpcuser):$($b.rpcpassword)" } else { (Get-Content $b.rpccookiefile -Raw).Trim() }
    $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cred)) }
    $body = @{ jsonrpc = "1.0"; id = "s"; method = $method; params = @($params) } | ConvertTo-Json -Compress
    (Invoke-RestMethod -Uri $b.rpcurl -Method Post -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 5).result
  }
  for ($i = 0; $i -lt 45; $i++) { try { $ni = ExtRpc "getnetworkinfo" @(); if ($ni) { break } } catch {}; Start-Sleep 2 }
  if ($ni) {
    $extVersion = "" + $ni.subversion; $knotsShort = ($KNOTS_VER.Split('.')[0..2]) -join '.'; Ok "Bitcoin Knots answers RPC: $extVersion"
    if ($extVersion -notmatch 'Knots') { Warn "this does not look like Bitcoin Knots (BLAKE2b fork): $extVersion - the gateway can only build blocks for this chain with the fork's node" }
    elseif ($extVersion -notmatch [regex]::Escape($knotsShort)) { Warn "Bitcoin Knots v$knotsShort is the current release; yours is $extVersion - please update it from bitcoinknots.org / GitHub, the same install-over-the-top as usual" }
    # same chain? The upstream Bitcoin Knots says 'Knots' too. A block hash settles it: the published snapshot's height and hash.
    if ($snap -and $snap.block_hash) {
      try { $bh = ExtRpc "getblockchaininfo" @()
            if ([int]$bh.blocks -ge [int]$snap.height) {
              $hh = "" + (ExtRpc "getblockhash" @([int]$snap.height))
              if ($hh -eq $snap.block_hash) { Ok "chain check: block $($snap.height) matches the Bitcoin BLAKE2b chain (height $($bh.blocks))" }
              else { Warn "chain check FAILED: this node's block $($snap.height) is $hh, the Bitcoin BLAKE2b chain's is $($snap.block_hash). This Bitcoin Knots follows another chain; the gateway cannot mine with it." }
            } else { Say "  chain check: node at height $($bh.blocks), below $($snap.height) - still syncing, checked later by datum-status" } } catch {}
    }
  } else { Warn "Bitcoin Knots is not answering RPC yet (not started, still loading, or server=1 did not take). datum-status shows it later; the gateway keeps trying every 30 s." }
} else {
  Start-ScheduledTask -TaskName "XorDatum Node"; Start-Sleep 3; Start-ScheduledTask -TaskName "XorDatum Gateway"; Start-Sleep 4
  if (-not (Get-Process bitcoind -ErrorAction SilentlyContinue)) { Die "the node did not start - see $NODE\debug.log" }
  if (-not (Get-Process ratum-gateway -ErrorAction SilentlyContinue)) { Die "the gateway did not start - see $LOGS\gateway.log" }
}

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
for ($i = 0; $i -lt $(if ($EXT -and $extVersion) { 40 } else { 20 }); $i++) {
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
if ($EXT) { Say "  Your Bitcoin Knots is the node: keep it running (and the PC awake, logged in) - the gateway waits whenever it is closed."; Say "  Its config: $EXT_DIR\bitcoin.conf (a backup of the old one sits next to it)." }
elseif ($doSnapshot) { Say "  The node started from the snapshot and is catching up the last few blocks - your ASICs get work within minutes." }
elseif ($hadChain) { Say "  The node restarted with its existing chain data and is catching up whatever it missed - your ASICs get work within minutes." }
else { Say "  The node is now syncing the chain from the start - 1 to 3 days on a small PC. Your ASICs get work automatically"; Say "  the moment it reaches the tip; until then the gateway waits. Leave the PC on (and not sleeping)." }
Say ""; Say "  Check on it any time (PowerShell):  powershell -ExecutionPolicy Bypass -File $ROOT\datum-status.ps1"
if (Test-Path "$ROOT\datum-pool.ps1") { Say "  Change the pool any time:           powershell -ExecutionPolicy Bypass -File $ROOT\datum-pool.ps1   (as administrator)" }
if ($isXor) { Say "  Your stats once shares flow:        $XOR_URL/miner/$ADDR" } elseif ($POOL_URL) { Say "  Your stats are on your pool's own site:  $POOL_URL" }
if ($EXT) { Say "  The gateway starts with Windows automatically. Power settings: make sure the PC does not sleep." }
else { Say "  Both programs start with Windows automatically. Power settings: make sure the PC does not sleep." }
Say ""
& powershell -ExecutionPolicy Bypass -File "$ROOT\datum-status.ps1"
