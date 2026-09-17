# Changelog

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
