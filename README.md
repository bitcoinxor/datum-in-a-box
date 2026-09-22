# DATUM-in-a-box — build your own blocks on the Bitcoin BLAKE2b chain

Run your **own** Bitcoin Knots (BLAKE2b) node and your **own** DATUM gateway. Your node picks the
transactions, your gateway serves work to your ASICs, and the [Bitcoin Xor](https://xorpool.com/datum)
pool only coordinates the payout — every block pays you straight from its coinbase, TIDES-style,
minus **1%**. About an hour of setup, then the node syncs on its own.

```
 your ASICs ──stratum──▶ your gateway :23334 ──▶ your node        (templates)
                              │
                              └────DATUM────▶ datum.xorpool.com:28915   (payout split, 1%)
```

Nothing of yours touches the pool's servers except shares. The web version of this guide, with
copy buttons, is at **https://xorpool.com/datum/setup**.

## The easy way — one command

[`setup-datum.sh`](setup-datum.sh) does every step below. It asks a few questions (your payout
address, a name for your blocks, which DATUM pool to work with, and whether to download the chain
snapshot to skip the initial sync — Enter accepts the defaults), checks the machine, installs
both programs from their official releases with checksums verified, and starts everything. It
never deletes chain data and can be re-run to update. On a fresh Ubuntu or Debian box:

**Any DATUM pool.** The pool question defaults to Bitcoin Xor (xorpool.com, 1% fee), but option 2 takes
any other DATUM pool: its `host:port` and its public key (128 hex characters, published by the pool),
plus its web address if you like. The gateway checks that key on every connection, so the installer
validates its shape, and at the end it tells you plainly whether the pool answered and proved its key
or the handshake failed. The Windows and macOS installers ask the same.

```sh
curl -fsSLo setup-datum.sh https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/v1.6.0/setup-datum.sh
sudo bash setup-datum.sh
```

Prefer to see exactly what happens, or on a different distro? Keep reading — the manual steps are
the same thing.

## Windows — the same setup on a PC

[`setup-datum.ps1`](setup-datum.ps1) is the Windows version of the installer: Windows 10/11 64-bit,
the same questions, Bitcoin Knots and ratum-gateway from their official Windows builds (checksums
verified), installed under `C:\XorDatum`, both running as scheduled tasks that start with Windows
(no login needed), the one firewall rule for port 23334 on private networks, and the chain snapshot
if you want it (Windows 11's built-in `tar` reads zstd; Windows 10's does not, so there the node syncs
from scratch). Open PowerShell **as administrator** and paste:

```powershell
cd $env:USERPROFILE\Downloads
Invoke-WebRequest https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/v1.7.3/setup-datum.ps1 -OutFile setup-datum.ps1
powershell -ExecutionPolicy Bypass -File .\setup-datum.ps1
```

Check on it any time with `powershell -ExecutionPolicy Bypass -File C:\XorDatum\datum-status.ps1`.

**Already running Bitcoin Knots on that PC** (the wallet program, bitcoin-qt)? The script notices it and
offers to install only the gateway and use your node: two lines go into your `bitcoin.conf` (`server=1`
and a `blocknotify`; a backup is kept next to it), the gateway logs in with the node's cookie file, and
nothing else changes. Mining then happens while Bitcoin Knots is open; the gateway starts with Windows
and waits for it, and the script can add a Startup shortcut so the wallet opens at login. The node is
checked against the chain (its block hash at the snapshot height) and its version. If the script did not
find your node by itself, name its data folder: `-ExistingNode "C:\Users\you\AppData\Roaming\Bitcoin"`.
Windows only for now.

**Changing the pool later** (Windows): `powershell -ExecutionPolicy Bypass -File C:\XorDatum\datum-pool.ps1`
as administrator asks only which pool, rewrites the gateway config, restarts the gateway and says whether
the new pool answered. `-Xor` switches back to Bitcoin Xor without questions; `-Pool host:port -Key <hex>`
sets another pool without questions. The installer puts it in `C:\XorDatum`; it is also
[`datum-pool.ps1`](datum-pool.ps1) here.
Keep the PC from sleeping (Settings → System → Power). Xor Desk is Linux-only for now.

## macOS — the same setup on a Mac

[`setup-datum-macos.sh`](setup-datum-macos.sh) is the Mac version: Apple silicon or Intel, macOS 12 or newer,
the same questions, Bitcoin Knots and ratum-gateway from their official macOS builds (checksums
verified), installed under `/usr/local/xordatum`, both running as launchd system services that start
at boot (no login needed), and an option to stop the Mac from sleeping while plugged in. It needs
nothing installed first: no Homebrew, no Xcode tools, no python (it uses the perl and shasum that ship
with macOS). The chain snapshot works if your `tar` can read zstd (recent macOS) or Homebrew's `zstd`
is installed; otherwise the node syncs from scratch. Open Terminal and paste:

```bash
curl -fsSLo setup-datum-macos.sh https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/v1.6.0/setup-datum-macos.sh
sudo bash setup-datum-macos.sh
```

Check on it any time with `datum-status`. If macOS asks whether `bitcoind` or `ratum-gateway` may accept
incoming connections, allow it: that is your ASICs reaching the gateway. Xor Desk is Linux-only for now.

## Your node, your policy — `datum-policy`

The point of running your own gateway is that **your node decides what goes into your blocks**, not the pool. With nothing
changed your node uses the Bitcoin Knots defaults, and that is a perfectly good place to stay. When you want to choose for
yourself (a higher minimum fee, stricter limits on data, a different block size) the Linux installer gives you one command:

```bash
datum-policy                       # what is set now
datum-policy options               # every option you may set, from your node's own help, with defaults
datum-policy options fee           # ...only the ones mentioning "fee"
sudo datum-policy set blockmintxfee=0.00002
sudo datum-policy unset blockmintxfee
sudo datum-policy edit             # open the file, then apply
sudo datum-policy undo             # back to the policy before the last change
```

Your settings live in `/var/lib/knots/policy.conf`. The installer creates it once and never overwrites it. Applying a change
restarts the node (your miners get no new work for a minute or two), then checks that the node answers and can still
build a block template. If it cannot, the last policy that worked is put back automatically.

Policy decides what *you* relay and mine. It works inside the chain's consensus rules and cannot loosen them.

On an install made before v1.5.0 you can add the command without re-running the installer:

```bash
curl -fsSLo datum-policy https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/v1.5.0/datum-policy
sudo install -m 755 datum-policy /usr/local/bin/ && datum-policy
```

On macOS and Windows the same `policy.conf` sits next to `bitcoin.conf`; edit it and restart the node as the file describes.

## Xor Desk — a local dashboard for the box (optional, beta)

The installer offers **Xor Desk**: a small web app that runs *on the mining machine* and shows
node sync, gateway state, connected rigs and your place in the pool's payout window; lets you
change the payout address, block name and pool endpoint; and has one-click update, chain snapshot,
restart and logs. Python standard library, one file ([`xordesk/xordesk.py`](xordesk/xordesk.py)),
MIT, pool-agnostic (any DATUM prime; earnings are pulled from the pool's public API when it has one).

It binds to this machine only (`http://127.0.0.1:8090`; from elsewhere open an SSH tunnel:
`ssh -L 8090:127.0.0.1:8090 you@your-box`), or to your LAN if the installer detects a private
address and you say yes. Password is generated by the installer and shown once. It sends nothing
anywhere — the only outbound requests are pulls you trigger by opening a page (pool stats, the
snapshot index, the release list on GitHub).

## 1 · Get a machine

A spare Linux box or a small VPS — anything that stays on. The node is pruned, so it stays small once synced.

| | |
|---|---|
| CPU | 2 cores (more makes the first sync faster) |
| RAM | **4 GB** recommended; 2 GB + a 2 GB swap file works once synced |
| Disk | **40 GB SSD** (the pruned node uses ~14 GB, the rest is headroom) |
| OS | any current Ubuntu or Debian (Ubuntu 26.04 if you're installing fresh), x86-64 or arm64 |
| Network | the first sync downloads the whole chain once (~750 GB), after that it is negligible |
| Where | anywhere — your ASICs talk to *your* gateway, and the gateway's link to the pool is latency-tolerant |

Updates, and a service user for the two programs to run as:

```sh
sudo apt update && sudo apt -y upgrade && sudo apt -y install curl
sudo useradd -r -m -d /var/lib/knots -s /usr/sbin/nologin knots
```

This guide doesn't set up a firewall. If your machine or provider has one, the only port that needs
to be reachable is 23334 (the gateway), and only from your miners. The node's RPC only listens on the
machine itself.

## 2 · Install Bitcoin Knots (BLAKE2b fork)

The chain runs on **Bitcoin Knots v29.4.2.knots20260508** — use that exact release from
[github.com/bitcoinknots/bitcoin/releases](https://github.com/bitcoinknots/bitcoin/releases/tag/v29.4.2.knots20260508).
Older builds don't know the fork's proof of work.

```sh
cd /tmp
V=29.4.2.knots20260508; A=$(uname -m | sed 's/x86_64/x86_64-linux-gnu/; s/aarch64/aarch64-linux-gnu/')
curl -LO https://github.com/bitcoinknots/bitcoin/releases/download/v$V/bitcoin-$V-$A.tar.gz
curl -LO https://github.com/bitcoinknots/bitcoin/releases/download/v$V/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS          # must print: bitcoin-...tar.gz: OK
tar xzf bitcoin-$V-$A.tar.gz
sudo install -m 755 bitcoin-$V/bin/bitcoind bitcoin-$V/bin/bitcoin-cli /usr/local/bin/
bitcoind --version | head -1                        # Bitcoin Knots daemon version v29.4.2.knots20260508
```

## 3 · Configure and sync the node

Copy [`manual/bitcoin.conf`](manual/bitcoin.conf) to `/var/lib/knots/bitcoin.conf` and
[`manual/knotsd.service`](manual/knotsd.service) to `/etc/systemd/system/knotsd.service`.
**Change the RPC password** on the `rpcpassword=` line to anything long and random (you'll use it
again in step 4). Then:

```sh
sudo chown knots:knots /var/lib/knots/bitcoin.conf && sudo chmod 600 /var/lib/knots/bitcoin.conf
sudo systemctl daemon-reload && sudo systemctl enable --now knotsd
sudo -u knots bitcoin-cli -datadir=/var/lib/knots getblockchaininfo | grep -E 'blocks|verificationprogress'
```

**From scratch this takes 1–3 days on a 2-core VPS** (the full Bitcoin history up to the fork,
plus the fork blocks). It runs unattended; do step 4 meanwhile. **Or skip it with the snapshot** — a
copy of our node's verified pruned chain (~10 GB, rebuilt weekly; `latest.json` names the current
one). You trust this copy of history up to the snapshot height, verify its checksum, and your node
verifies every block after it — the usual bootstrap trust model. Fetch, verify, swap in, confirm:

```sh
cd /var/tmp && curl -fsS https://snapshot.xorpool.com/latest.json -o latest.json
F=$(python3 -c 'import json;print(json.load(open("latest.json"))["file"]')
curl -fL -C - -o $F https://snapshot.xorpool.com/$F
echo "$(python3 -c 'import json;print(json.load(open("latest.json"))["sha256"]')  $F" | sha256sum -c   # must print: OK - stop here if it doesn't
sudo apt -y install zstd
sudo systemctl stop knotsd && sudo rm -rf /var/lib/knots/blocks /var/lib/knots/chainstate
sudo tar -C /var/lib/knots --use-compress-program=unzstd -xf $F && sudo chown -R knots:knots /var/lib/knots
sudo systemctl start knotsd && rm -f $F
H=$(python3 -c 'import json;print(json.load(open("latest.json"))["height"]'); sleep 20
sudo -u knots bitcoin-cli -datadir=/var/lib/knots getblockhash $H; python3 -c 'import json;print(json.load(open("latest.json"))["block_hash"]')   # the two hashes must match
```

## 4 · Install the DATUM gateway (ratum)

[ratum-gateway](https://github.com/iohzrd/ratum) is an open-source (AGPL) DATUM gateway written
for this chain: it builds templates from your node and speaks the 164-byte v2 header to BLAKE2b
hardware. Prebuilt static binaries are on its
[release page](https://github.com/iohzrd/ratum/releases/tag/v0.1.28).

```sh
cd /tmp
R=0.1.28; A=$(uname -m | sed 's/x86_64/x86_64-linux-musl/; s/aarch64/aarch64-linux-musl/')
curl -LO https://github.com/iohzrd/ratum/releases/download/v$R/ratum-gateway-$R-$A.tar.gz
curl -LO https://github.com/iohzrd/ratum/releases/download/v$R/ratum-gateway-$R-$A.tar.gz.sha256
sha256sum -c ratum-gateway-$R-$A.tar.gz.sha256      # must print: OK
tar xzf ratum-gateway-$R-$A.tar.gz
sudo install -m 755 $(find . -name ratum-gateway -type f | head -1) /usr/local/bin/ratum-gateway
ratum-gateway --version
```

Copy [`manual/gateway.json`](manual/gateway.json) to `/etc/ratum/gateway.json` and
[`manual/ratum-gateway.service`](manual/ratum-gateway.service) to
`/etc/systemd/system/ratum-gateway.service`. **Three things are yours to change** — everything
else already points at the pool:

- `bitcoind.rpcpassword` — the password you put in `bitcoin.conf` in step 3.
- `mining.pool_address` — **your own address** (a wallet you hold the keys to,
  [not an exchange](https://xorpool.com/wallet)). This is where every block pays you.
- `mining.coinbase_tag_secondary` — **your name**, up to 60 characters. Blocks you help find are
  stamped *Bitcoin Xor* plus this, on-chain, forever. Put the same name in `coinbase_tag_primary`.

```sh
sudo chown -R knots:knots /etc/ratum && sudo chmod 640 /etc/ratum/gateway.json
sudo systemctl daemon-reload && sudo systemctl enable --now ratum-gateway
sleep 3; journalctl -u ratum-gateway -n 20 --no-pager
```

You want to see the pool handshake in those lines:

```
INFO  [ratum_gateway::datum] connecting to DATUM pool datum.xorpool.com:28915
INFO  [ratum_gateway::datum] DATUM pool configuration: prime_id 0x00000001, tag "Bitcoin Xor", min diff ...
INFO  [ratum_gateway::datum] DATUM pool anti-block-withholding: enabled
```

Once the node is at the tip you'll also see `Stratum job ... ready` lines every ~40 s and on every
new block. Until then it says it's waiting for the node — that's normal.

What the keys mean: `pool_pass_workers` credits all your work to `pool_address` and passes each
ASIC's worker name for stats. (Set `pool_pass_full_users: true` instead if each ASIC should be
paid to its own address — then the ASIC username must *be* that address.) `gateway_fee_bps: 0`
means no gateway fee — you are the gateway. `pooled_mining_only` pauses work if the pool link ever
drops, rather than serving stale jobs.

## 5 · Point your ASICs at your gateway

On each miner (Goldshell, Antminer, etc.), set the pool to **your** gateway, not to xorpool.com:

| | |
|---|---|
| URL | `stratum+tcp://YOUR-GATEWAY-IP:23334` |
| Worker | `anything.rig1` |
| Password | `x` |

The part after the dot is the worker name you'll see in stats; the part before it can be anything
with the config above (your address is credited from `pool_address`).

Check it's working: the gateway's status page is on the box at `http://127.0.0.1:8000/` (reach it
over an SSH tunnel: `ssh -L 8000:127.0.0.1:8000 you@your-box`), and within a couple of minutes of
your first share your address appears at `https://xorpool.com/datum/miner/<your address>`.

## 6 · Keep it running

- Both services restart on their own and come back after a reboot.
- After the first sync, drop `dbcache` in `bitcoin.conf` to `400` and
  `sudo systemctl restart knotsd` if the box is short on RAM.
- Logs: `journalctl -u knotsd -f` and `journalctl -u ratum-gateway -f`. The installer also puts a
  `datum-status` command on the box.
- Upgrades: when a new Knots or ratum release lands, repeat step 2 or 4 (or re-run the installer)
  and restart the service. Watch [Telegram](https://t.me/bitcoinxor) for consensus-relevant releases.

## 7 · If something's off

- **Gateway says no work / waiting for node** — the node isn't at the tip yet, or the template
  doesn't list the fork rule. Check:
  `sudo -u knots bitcoin-cli -datadir=/var/lib/knots getblocktemplate '{"rules":["segwit","blake2b"]}' | grep -A6 rules`
  must include `!blake2b`.
- **Node stuck with no peers** — confirm the two `addnode` lines and that outbound traffic is
  allowed; `sudo -u knots bitcoin-cli -datadir=/var/lib/knots getconnectioncount` should be > 0.
- **Shares rejected: `BadUsername`** — `pool_address` (or an ASIC username, if you use
  `pool_pass_full_users`) is not a valid address on this chain. Typos like `bc1g…` for `bc1q…` do
  exactly this.
- **RPC timeouts in the gateway log on a small VPS** — usually the node validating a fresh block;
  harmless if occasional. If constant, give the node more RAM/`dbcache` or fewer `maxconnections`.
- **ASICs can't connect** — something between them and the gateway blocks port 23334 (a firewall on
  the machine or at the provider). Test with `nc -vz YOUR-GATEWAY-IP 23334` from the miners' network.

Still stuck? Ask in [Telegram](https://t.me/bitcoinxor).

---

*Your node, your template, your keys.* The pool never holds coins and never sees your machine; its
job is the payout split. Not affiliated with Bitcoin Core, Bitcoin Knots or the fork's developers.
MIT licensed — see [LICENSE](LICENSE). The Docker variant in [`docker/`](docker/) is a
work-in-progress sketch and does not work yet.
