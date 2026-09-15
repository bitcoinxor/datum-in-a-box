# Changelog

## v1.0.1 — 2026-09-15
- Fix: the installer aborted right after the questions (exit 141, SIGPIPE) while generating the RPC password.
- Error messages now report the real failing line.

## v1.0.0 — 2026-09-15
- First release: interactive installer `setup-datum.sh` (Bitcoin Knots v29.4.1.knots20260508 + ratum-gateway 0.1.28,
  checksums verified, safe to re-run) and the manual step-by-step in `README.md` / `manual/`.
- Docker variant moved to `docker/` as a work-in-progress sketch; images are not published.
