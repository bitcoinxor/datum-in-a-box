# datum-status.ps1 - how is my DATUM setup doing? (Windows, for a setup made by setup-datum.ps1)
# Usage: powershell -ExecutionPolicy Bypass -File C:\XorDatum\datum-status.ps1     (no admin needed)
# Shows: node and gateway running or not, chain height and sync, peers and node version, which pool the gateway works with and
# whether its link is up, the gateway's hashrate and share counts, and where the logs are.
# Source: https://github.com/bitcoinxor/datum-in-a-box
$ROOT = if ($env:XORDATUM_ROOT) { $env:XORDATUM_ROOT } else { "C:\XorDatum" }
$ext = Test-Path "$ROOT\existing-node.txt"   # the node is the owner's own Bitcoin Knots (wallet program), not one this script runs
# node RPC straight over HTTP with the login the gateway uses (gateway.json): cookie file or user/password
$gwc = $null; try { $gwc = Get-Content "$ROOT\gateway\gateway.json" -Raw | ConvertFrom-Json } catch {}
function NodeRpc($method) {
  $b = $gwc.bitcoind; $cred = if ($b.rpcuser) { "$($b.rpcuser):$($b.rpcpassword)" } else { (Get-Content $b.rpccookiefile -Raw -ErrorAction Stop).Trim() }
  $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cred)) }
  (Invoke-RestMethod -Uri $b.rpcurl -Method Post -Headers $h -ContentType 'application/json' -Body ('{"jsonrpc":"1.0","id":"s","method":"' + $method + '","params":[]}') -TimeoutSec 5).result
}
$n = (Get-Process bitcoind, bitcoin-qt -ErrorAction SilentlyContinue) -ne $null; $g = (Get-Process ratum-gateway -ErrorAction SilentlyContinue) -ne $null
Write-Host ("node:     " + $(if ($n) {"running"} else { if ($ext) {"NOT running - start Bitcoin Knots"} else {"NOT running"} }) + "    gateway: " + $(if ($g) {"running"} else { if ($ext -and -not $n) {"waiting for the node"} else {"NOT running"} }))
try { $i = NodeRpc getblockchaininfo; $p = [math]::Round($i.verificationprogress*100,2)
  if ($p -gt 99.99) { Write-Host "chain:    height $($i.blocks)  at tip" } else { Write-Host "chain:    height $($i.blocks)  syncing $p%" }
  Write-Host "peers:    $(NodeRpc getconnectioncount)   version: $((NodeRpc getnetworkinfo).subversion)" } catch { Write-Host "chain:    node starting / not answering RPC yet" }
# which pool, and is the link to it up? Name by public key (a pool is its key), host:port from the config, state from the gateway API
$XOR_KEY = "b83aedbba54ba2aa605c76859d97aebd16dece3284402b9fc874778a974da4acbb449f6ccda61625d700036f0487a05f5184f79a07abf2880da77352f4cc487e"
try { $d = $gwc.datum; $pk = ("" + $d.pool_pubkey).ToLower(); $pname = if ($pk -eq $XOR_KEY) { "Bitcoin Xor" } elseif ($d.pool_url) { "" + $d.pool_url } else { "key " + $pk.Substring(0, 8) + "..." }
  $link = ""; try { $link = "" + (Invoke-RestMethod http://127.0.0.1:8000/stats.json -TimeoutSec 3).status } catch {}
  $ls = if ($link -eq "Connected and Ready") { "link UP" } elseif ($link) { "link: $link" } elseif ($g) { "link: not answering yet" } else { "link DOWN (gateway not running)" }
  Write-Host "pool:     $pname at $($d.pool_host):$($d.pool_port)   $ls" } catch { Write-Host "pool:     (no gateway config)" }
# live smoothed estimate (needs the API password from the gateway config), else the mean of the last five COMPLETED minutes;
# never the newest history point, which is the minute still in progress and made a small rig read 0.00 half the time
try { $hdr = @{}; try { $gp = $gwc.api.admin_password; if ($gp) { $hdr = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$gp")) } } } catch {}
  $s = Invoke-RestMethod http://127.0.0.1:8000/stats.json -TimeoutSec 3 -Headers $hdr
  $ths = 0.0; if ($s.stratum -and $s.stratum.hashrate_ths -gt 0) { $ths = [double]$s.stratum.hashrate_ths }
  else { $hist = @($s.hashrate.history | ForEach-Object { $_[1] }); if ($hist.Count -gt 1) { $from = [Math]::Max(0, $hist.Count - 6); $doneMin = $hist[$from..($hist.Count - 2)]; $ths = (($doneMin | Measure-Object -Average).Average) / 1e12 } }
  Write-Host ("gateway:  {0:N2} TH/s   shares accepted {1}   rejected {2}" -f $ths, $s.shares_accepted.count, $s.shares_rejected.count) } catch { Write-Host "gateway:  waiting for the node / not answering yet" }
Write-Host ("log:      $ROOT\logs\gateway.log" + $(if ($ext) { "" } else { "   node: $ROOT\node\debug.log" }))
