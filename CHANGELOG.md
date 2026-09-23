# Changelog

## v1.7.4 — 2026-09-21
- Linux and macOS: the node's `dbcache` is now sized in three tiers, 600 below 3.5 GB RAM, 1000 from 3.5 GB, 2000 from 7 GB (was 2000 from 3.5 GB, which on a 4 GB machine slowly crowds out the page cache the node needs to connect blocks fast). Existing installs: `sudo datum-policy set dbcache=1000 --yes`.
- Windows: `datum-status` shows which pool the gateway works with and whether the link to it is up (`pool: Bitcoin Xor at hk.datum.xorpool.com:28915   link UP`). Shares accepted on the PC count only while that link is up, and a miner whose gateway had lost its pool link could not tell from the old output.
- Windows: `datum-status.ps1` and `datum-pool.ps1` are files in this repo, fetched by the installer from the release (mirror as fallback), so either can be updated without re-running the installer: `Invoke-WebRequest https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/v1.7.4/datum-status.ps1 -OutFile C:\XorDatum\datum-status.ps1`.

## v1.7.3 — 2026-09-21
- **Windows: `datum-pool.ps1`**, a one-question helper to change the pool later (or `-Xor` / `-Pool host:port -Key <hex>` with no questions): rewrites the pool part of the gateway config, restarts the gateway, reports the handshake. The installer places it in `C:\XorDatum` and names it at the end.
- **Windows: the gateway needs Microsoft's Visual C++ runtime** (`vcruntime140.dll`), which a bare Windows 10 does not have; without it `ratum-gateway.exe` exits at once printing nothing, and v1.7.x showed an empty "OK" and an empty log (first Windows 10 run). The installer now installs the runtime from Microsoft when it is missing (installer checked for Microsoft's Authenticode signature), refuses to continue if the gateway's `--version` does not answer, and the gateway loop writes each start and exit code to the log so a launch failure is never silent.
- **Windows, existing wallet: the gateway's RPC login is whitelisted.** `rpcwhitelist=<gateway user>:<14 block-building calls>` + `rpcwhitelistdefault=0` go into the owner's `bitcoin.conf` next to `server=1`, so the login the gateway holds (the cookie) cannot reach any wallet call even if the gateway or its machine account is compromised; the wallet program itself is unaffected (it does not use RPC), other RPC users are unaffected. Verified on a 29.4.2 node: template fetch and job building work, `getwalletinfo` / `sendtoaddress` / `dumpprivkey` are refused with 403.

## v1.7.2 — 2026-09-21
- Windows: GitHub's release downloads fail often from China ("unable to connect to the remote server", seen on the first Windows 10 run). The two Windows builds are now also on our own storage (`snapshot.xorpool.com/mirror/`), used only when GitHub fails, and both files' checksums are pinned in the script from the projects' own SHA256SUMS / `.sha256`, so a download from either place is checked against the authors' values. One request per file instead of two.

## v1.7.1 — 2026-09-21
- Windows: the wallet program keeps the data folder chosen at its first start in the registry (`HKCU\Software\Bitcoin\Bitcoin-Qt\strDataDir`), not on its command line, so a wallet with a custom folder went unnoticed by v1.7.0 and the script offered a fresh node. It now reads that key for the current user and every loaded user hive. If Bitcoin Knots is installed but no data folder is found, it says so and points at `-ExistingNode` before asking anything. Found on the first Windows 10 run.

## v1.7.0 — 2026-09-21
- **Windows: use the Bitcoin Knots you already run.** Many Windows miners already have the Bitcoin Knots wallet program (bitcoin-qt) open with a synced chain. The installer now finds it (running process, `-datadir`, `%APPDATA%\Bitcoin`, or `-ExistingNode <folder>`) and offers to install only the DATUM gateway against it: `server=1` and a `blocknotify` line go to the top of its `bitcoin.conf` (existing `server=`/`blocknotify=` lines commented out, a dated backup next to it, the file's own encoding and line endings kept), the gateway logs in with the node's cookie file (or the file's own rpcuser/rpcpassword), and the node itself is never stopped or touched otherwise. The gateway runs in a restart loop under its scheduled task, so it waits while the wallet is closed and picks up the moment it opens; optional Startup shortcut for the wallet. After the wallet is reopened the script reads the node's version through the gateway's login and checks the node is on the Bitcoin BLAKE2b chain (its hash at the published snapshot height must match). Linux and macOS installers unchanged.
- Windows: `datum-status.ps1` talks to the node over RPC with the gateway's own login (no bitcoin-cli), shows the node version, and works for both kinds of node.
- Windows: the chain snapshot needs a `tar` that reads zstd, which Windows 11 has and Windows 10 does not; the README says so. A snapshot path for Windows 10 is next.

## v1.6.0 — 2026-09-21
- **Bitcoin Knots v29.4.2.knots20260508** (was v29.4.1), the release that carries the long coinbase maturity soft fork: from block 973440, newly mined coins cannot be spent until block 979920 (about 45 days). Every node that builds blocks should be on it before block 973540. **To update an existing install, run the installer again**: your answers, chain data and `policy.conf` are kept. Linux, Windows and macOS.
- Fix (Linux): a re-run that installed a newer node left the old one running from memory until the next reboot. The installer now restarts the node onto the new version and waits for it to answer; the gateway keeps your miners on their current work for the few seconds that takes.

## v1.5.0 — 2026-09-17
- **Your node, your policy.** New `datum-policy` command (Linux): choose what your node relays and what goes into the blocks your gateway builds. `datum-policy options` lists every relay, block-building and mempool option straight from your node's own help text with its default; `set`, `unset`, `edit`, `apply` and `undo` change them. Every option is checked against the node binary before anything is touched. Applying restarts the node, waits for it to answer and asks it for a block template; if the node refuses to start or cannot build a template, the last policy that worked is put back and the node restarted again, and the rejected file is kept for you to look at. Works on existing installs without re-running the installer: `curl -fsSLo datum-policy https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/v1.5.0/datum-policy && sudo install -m 755 datum-policy /usr/local/bin/`.
- **Fix (all): a re-run no longer wipes hand-made node settings.** Every installer rewrote `bitcoin.conf` from scratch on each run, so a policy change made by hand silently disappeared at the next update. Your settings now live in `policy.conf` next to it, created once and never overwritten; `bitcoin.conf` includes it. The node's main file wins over an included one (checked on the real binary), so when you set `maxmempool` or `dbcache` yourself the installer leaves its own line commented out.
- macOS and Windows get the same `policy.conf` (edit it, then restart the node: the file says how); the `datum-policy` command itself is Linux only for now.
- The installer takes `DATUM_RAW_BASE` to fetch its helper files from somewhere other than the release tag, so a release can be tested end to end before the tag exists.

## v1.4.1 — 2026-09-17
- `datum-status` showed 0.00 TH/s half the time for small rigs: it read the newest point of the gateway's per-minute history, which is the minute still in progress. It now shows the gateway's live smoothed estimate (and the rig count), falling back to the average of the last five completed minutes. Linux, Windows and macOS.

## v1.4.0 — 2026-09-17
- **Any DATUM pool.** Question 3 is now "which pool": 1) Bitcoin Xor (the default, Enter), 2) another DATUM pool, which asks for its `host:port`, its public key (validated as 128 hex characters) and an optional web address. The summary, the fee line and the stats link no longer claim xorpool's terms for another pool. Same in the Linux, Windows and macOS installers; re-runs remember the choice, and `--noninteractive` takes pool, key and address from the gateway config (the file Xor Desk's settings page edits).
- **Pool handshake check.** After starting, every installer waits for the gateway to report "Connected and Ready" and says so, or says plainly that the handshake failed (wrong host, port or key), instead of assuming success. Tested with a deliberately wrong key.
- Fix (Linux): a re-run rewrote the gateway config but never restarted a running gateway, so changed answers did not take effect. It restarts it now.
- Fix (all): a re-run on a machine with less than 25 GB free refused to start even though the node's data was already there; an existing install now needs 5 GB.
- Fix (all): the gateway's miner-lookup API defaulted to the same port as its main API and logged "Address in use" on every start; it now gets its own local port 8001.

## v1.3.0 — 2026-09-16
- New: `setup-datum-macos.sh`, the installer for macOS (Apple silicon and Intel). Same questions and checks as the Linux script; official macOS builds of Knots and ratum with verified checksums; launchd system services under `/usr/local/xordatum` that start at boot and stop the node cleanly (180 s ExitTimeOut); optional 'never sleep while plugged in'; snapshot restore when zstd is available. Works on a stock Mac with bash 3.2: no Homebrew, Xcode tools or python required (address validation in perl). Not yet run on a real Mac - first-run reports welcome.

## v1.2.3 — 2026-09-15
- Windows: on a re-run the node is asked to shut down and the script waits for it (up to 3 minutes) before anything else. Stopping the scheduled task first killed bitcoind outright, so the next start rewound to the last flushed state and replayed. The finish text now also distinguishes "restarted with existing chain data" from a from-scratch sync.

## v1.2.2 — 2026-09-15
- Windows: `datum-status.ps1` and the installer's snapshot check called bitcoin-cli through a helper that returned nothing (`cli` is a built-in alias of Clear-Item; a declared `$args` parameter swallows arguments), so status showed "syncing 0%" and the snapshot block hash could not be verified. Fixed; the hash is verified again after the restore.
- Windows: "Point your ASICs at" shows the address on the interface with the default route (the real LAN) instead of the first adapter, which on many PCs is a Hyper-V / WSL virtual switch.

## v1.2.1 — 2026-09-15
- Windows installer: download the `win64-pgpverifiable.zip` Knots build (Knots publishes no plain `win64.zip`). Found on the first real Windows run.

## v1.2.0 — 2026-09-15
- Installer flags `--noninteractive` (answers from /etc/xordesk.json) and `--snapshot`; Xor Desk's Update and Snapshot buttons use them. A failed Xor Desk download no longer fails a node/gateway update.
- Windows installer `setup-datum.ps1`: same questions and checks, official Windows builds with verified checksums, scheduled tasks that start with Windows, firewall rule for 23334, snapshot via the built-in tar.
- Xor Desk 0.1: optional local web dashboard installed by the script (overview, rigs, settings, update / snapshot / restart, logs). Localhost by default, LAN opt-in, password shown once. Sends nothing anywhere.
- Installer sets a gateway API admin password (needed for the rigs table) and keeps it across re-runs.

## v1.1.0 — 2026-09-15
- Chain snapshot: the installer offers to download a pruned-chain snapshot (~12 GB, from snapshot.xorpool.com) so the node starts at the tip in minutes instead of syncing for days. It verifies the sha256 before use, swaps only blocks/ and chainstate/, and checks the block hash at the snapshot height against the published one. Manual steps for the same in the README.
- The snapshot is rebuilt weekly by `snapshot-make.sh` (included) and described by `latest.json`.
- Pool host must resolve in DNS; answers can be piped on stdin; progress bar on the download.

## v1.0.2 — 2026-09-15
- `datum-status` prints readable hashrate and share counts, and a calm "waiting for the node to finish syncing" line instead of the gateway's initial-sync error.
- Fix doubled program names in the OK lines.
- Verified end to end on a fresh DigitalOcean droplet: install, sync, own templates, shares credited on the pool.

## v1.0.1 — 2026-09-15
- Fix: the installer aborted right after the questions (exit 141, SIGPIPE) while generating the RPC password.
- Error messages now report the real failing line.

## v1.0.0 — 2026-09-15
- First release: interactive installer `setup-datum.sh` (Bitcoin Knots v29.4.1.knots20260508 + ratum-gateway 0.1.28,
  checksums verified, safe to re-run) and the manual step-by-step in `README.md` / `manual/`.
- Docker variant moved to `docker/` as a work-in-progress sketch; images are not published.
