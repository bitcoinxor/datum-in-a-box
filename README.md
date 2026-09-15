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

[`setup-datum.sh`](setup-datum.sh) does every step below. It asks three questions (your payout
address, a name for your blocks, which network your ASICs are on), checks the machine, installs
both programs from their official releases with checksums verified, and starts everything. It
never deletes chain data and can be re-run to update. On a fresh Ubuntu or Debian box:

```sh
curl -fsSLo setup-datum.sh https://xorpool.com/datum/setup.sh
less setup-datum.sh          # read it first - it is short and commented (q to quit)
sudo bash setup-datum.sh
```

Prefer to see exactly what happens, or on a different distro? Keep reading — the manual steps are
the same thing.

## 1 · Get a machine

A small VPS or any spare Linux box. The node is pruned, so it stays small once synced.

| | |
|---|---|
| CPU | 2 cores (more makes the first sync faster) |
| RAM | **4 GB** recommended; 2 GB + a 2 GB swap file works once synced |
| Disk | **40 GB SSD** (the pruned node uses ~14 GB, the rest is headroom) |
| OS | Ubuntu 26.04 (or 24.04) or Debian 12, x86-64 or arm64 |
| Network | the first sync downloads the whole chain once (~750 GB), after that it is negligible |
| Where | anywhere — your ASICs talk to *your* gateway, and the gateway's link to the pool is latency-tolerant |

Updates, a service user, and a firewall that only lets your miners in. Edit the `192.168.0.0/16`
line to the network your ASICs are on (or their public IP):

```sh
sudo apt update && sudo apt -y upgrade && sudo apt -y install curl ufw
sudo useradd -r -m -d /var/lib/knots -s /usr/sbin/nologin knots
sudo ufw allow 22/tcp
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow from 192.168.0.0/16 to any port 23334 proto tcp   # <- the network your ASICs are on
sudo ufw --force enable
```

Only port 23334 (your gateway) needs to be reachable, and only from your miners. The firewall is
not active until the last line, and SSH is allowed before that. Never expose the node's RPC port.

## 2 · Install Bitcoin Knots (BLAKE2b fork)

The chain runs on **Bitcoin Knots v29.4.1.knots20260508** — use that exact release from
[github.com/bitcoinknots/bitcoin/releases](https://github.com/bitcoinknots/bitcoin/releases/tag/v29.4.1.knots20260508).
Older builds don't know the fork's proof of work.

```sh
cd /tmp
V=29.4.1.knots20260508; A=$(uname -m | sed 's/x86_64/x86_64-linux-gnu/; s/aarch64/aarch64-linux-gnu/')
curl -LO https://github.com/bitcoinknots/bitcoin/releases/download/v$V/bitcoin-$V-$A.tar.gz
curl -LO https://github.com/bitcoinknots/bitcoin/releases/download/v$V/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS          # must print: bitcoin-...tar.gz: OK
tar xzf bitcoin-$V-$A.tar.gz
sudo install -m 755 bitcoin-$V/bin/bitcoind bitcoin-$V/bin/bitcoin-cli /usr/local/bin/
bitcoind --version | head -1                        # Bitcoin Knots daemon version v29.4.1.knots20260508
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

**This takes a while: 1–3 days on a 2-core VPS** (it is the full Bitcoin history up to the fork,
plus the fork blocks). One-time, unattended. Do step 4 now while it syncs — the gateway simply
waits until the node reaches the tip. Don't want to wait? Ask in
[Telegram](https://t.me/bitcoinxor) about a pruned chain snapshot to start from; you still
validate every block from there on.

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
- **ASICs can't connect** — the firewall rule in step 1 must match the network the miners are on;
  test with `nc -vz YOUR-GATEWAY-IP 23334` from that network.

Still stuck? Ask in [Telegram](https://t.me/bitcoinxor).

---

*Your node, your template, your keys.* The pool never holds coins and never sees your machine; its
job is the payout split. Not affiliated with Bitcoin Core, Bitcoin Knots or the fork's developers.
MIT licensed — see [LICENSE](LICENSE). The Docker variant in [`docker/`](docker/) is a
work-in-progress sketch and does not work yet.
