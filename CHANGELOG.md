# Changelog

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
