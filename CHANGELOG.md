# Changelog

## v1.2.0 — 2026-09-15
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
