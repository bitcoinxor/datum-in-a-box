# Changelog

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
