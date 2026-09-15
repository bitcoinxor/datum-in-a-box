# DATUM-in-a-box — design sketch

Goal: onboard miners (esp. Chinese farms) onto **real DATUM** (own node + own gateway = own block
templates) with near-zero effort, so decentralization is genuine and NOT just "stevo hosts everyone's
nodes." You ship the *recipe + a snapshot*; they run it on *their own* $5-10/mo VPS.

## Architecture

```
 miner's ASICs ──stratum──▶ [ratum-gateway] ──DATUM──▶ datum.xorpool.com:28915 (your prime)
   (point here)                    │                     = own templates, TIDES payout, BYO fee
                                    ▼
                          [knotsd: Knots BLAKE2b, pruned]  ← bootstrapped from your snapshot
                          builds THEIR template from THEIR mempool  ← the decentralization win
```
One VPS, two containers, they edit **one line** (their payout address).

## docker-compose.yml (sketch)

```yaml
name: datum-in-a-box
services:
  node:                                   # the fork full node, pruned
    image: bitcoinxor/knotsd:latest       # YOU build/publish this (fork binary in an image)
    volumes: [ node-data:/data ]
    command: >
      -datadir=/data -prune=10000 -server=1
      -rpcbind=0.0.0.0 -rpcallowip=172.16.0.0/12 -rpcuser=xor -rpcpassword=${RPC_PASS}
      -zmqpubhashblock=tcp://0.0.0.0:28332
      -minrelaytxfee=0.00001 -blockmintxfee=0.00001     # clean-mempool defaults baked in
    restart: unless-stopped

  gateway:                                # ratum-gateway in BYO mode -> your prime
    image: bitcoinxor/ratum-gateway:latest # build from iohzrd/ratum
    depends_on: [node]
    ports: [ "23334:23334" ]              # ASICs connect here
    environment:                          # an entrypoint renders gateway.json from these
      NODE_RPC:      http://node:8332
      NODE_RPC_USER: xor
      NODE_RPC_PASS: ${RPC_PASS}
      DATUM_POOL_HOST:   ${POOL_HOST}     # datum.xorpool.com   (blank = fully solo, keep 100%)
      DATUM_POOL_PORT:   "28915"
      DATUM_POOL_PUBKEY: ${POOL_PUBKEY}
      MINING_POOL_ADDRESS: ${MINER_ADDRESS}   # <- the ONE thing they set
      STRATUM_PORT:      "23334"
    restart: unless-stopped
volumes: { node-data: {} }
```

## .env.example (whole config a miner touches)

```bash
# CHANGE THIS ONE LINE - your own wallet address (NOT an exchange)
MINER_ADDRESS=bc1qYOUR_OWN_ADDRESS

# leave everything below as-is
POOL_HOST=datum.xorpool.com     # blank this to mine fully solo (keep 100%, no pool)
POOL_PUBKEY=b83aedbb...487e     # your prime's pubkey (already public)
RPC_PASS=any-random-string
```

## setup.sh (one command, idiot-proofed)

1. prompt + VALIDATE the payout address (reject exchange-shaped mistakes if we can)
2. download `snapshot-<height>.tar.zst` -> verify SHA256 -> extract into node-data
3. write .env
4. `docker compose up -d`
5. print: "Point your miners at `<this-vps-ip>:23334`, username = your address"

No knobs to choose - sane defaults, hidden config.

## The snapshot (the "ultra-fast" killer feature)

- Periodically tar a **pruned datadir** (`blocks/` + `chainstate/`) at a recent height ->
  publish `snapshot-<height>.tar.zst` + `SHA256` (torrent + a cheap HTTP mirror).
- setup.sh downloads/verifies/extracts before first start -> node comes up **near-tip**, syncs in
  minutes not days.
- Decentralization note (in your favor): does NOT centralize - they still validate every block
  forward independently from the snapshot (same trust model as Bitcoin pruned bootstraps / assumeutxo:
  trust the pruned *history*, verify the *future*). If the fork's Knots supports **assumeutxo**, use
  that instead - cryptographically committed, cleaner.

## Economic lever (do on prime/gateway, separately - this is what actually converts them)

Bake into the queued pooled-vs-BYO fee split:
- **BYO (this box -> your prime): free / 0%** (prime fee-bps 0; charge the fee only via the *pooled*
  gateway surcharge).
- **Pooled (their ASICs -> your gateway): 1-3%.**

The box literally reads "run this, pay 0%." Profit-driven owners on cheap kWh WILL stand up a $5 VPS
to save 1-3%. That's the force - not ideology. Trade-off: you earn nothing from BYO miners, but the
pool is a reputation play now and "free + decentralized" is the strongest recruiting pitch.

## What YOU must produce (the real work; compose is the easy 10%)

1. **`bitcoinxor/knotsd` Docker image** - fork binary in a container (biggest lift).
2. **`bitcoinxor/ratum-gateway` image** - containerize the iohzrd/ratum build you already make.
3. **A gateway entrypoint** that renders gateway.json from env vars.
4. **Snapshot pipeline** - tar/publish/torrent + SHA256, refreshed ~weekly.
5. **Chinese + English quickstart + 3-min video**, pushed via Telegram/WeChat/Chinese mining forums.

## Windows / WSL support

Same compose runs in WSL2 (Docker Desktop or docker-engine-in-WSL). Container-wise it's identical.
THE catch, and it's mining-specific: WSL2 is NAT'd, so a container on `:23334` is reachable from
`localhost` on that PC but NOT from the LAN — the ASICs (other devices) can't connect by default.

- **Clean fix:** WSL2 **mirrored networking mode** — `%UserProfile%\.wslconfig`:
  ```ini
  [wsl2]
  networkingMode=mirrored
  ```
  Makes WSL share the host's NICs, so `:23334` is reachable on the PC's LAN IP. + a Windows Firewall
  allow-rule for 23334. (Needs Win11 + recent WSL.) Do NOT use `netsh portproxy` — WSL IP changes on
  reboot and it breaks.
- **Caveats:** a home Windows PC is a poor 24/7 node host (sleeps/reboots); real farms want the
  always-on VPS. And for the *least* technical operators, Docker-Desktop + WSL config is arguably
  *more* steps than "rent a $5 VPS, paste one command."
- **Position:** VPS = recommended/headline path (works everywhere, one command). WSL = "on my own PC"
  option; ship a Windows variant that auto-writes .wslconfig (mirrored) + installs Docker + adds the
  firewall rule. Second target, not the headline.

## Two decisions for you

- **Default mode:** BYO-*pooled* (own templates -> your prime, TIDES, on your pool) vs offer solo.
  Recommend: default pooled-to-your-prime (decentralization win AND keeps them on your pool), solo as
  a one-line .env change.
- **Fee:** truly-free BYO (earn $0 from them) vs BYO-at-1% (prime keeps its cut, they skip the pooled
  surcharge). Free = stronger magnet; 1% still earns. Your call - it's a rep play.

## Context / why

Market split: farm *owners* are profit-maximizers (cheap miners, cheap kWh) who employ non-technical
labor (the "mined-to-an-exchange-address" guy). You can't ideologically convince owners to
decentralize; you make BYO **nearly as easy as pooled** (this box + snapshot) AND **cheaper** (fee
split), and economics + ease do the converting. You already have one real BYO gateway in the wild
(external IP on :28915) doing it unaided - proof the path works. Don't burn out dragging the
farm-labor masses to run nodes; keeping them on non-custodial *pooled* DATUM is already a win.
