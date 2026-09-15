#!/usr/bin/env bash
# DATUM-in-a-box — one-command setup (Linux / VPS).
set -euo pipefail
cd "$(dirname "$0")"

echo "== DATUM-in-a-box setup =="
command -v docker >/dev/null || { echo "Docker not found. Install Docker first."; exit 1; }

# 1. .env
[ -f .env ] || cp .env.example .env

# 2. payout address (basic sanity check — must look like an address, and we nudge off exchanges)
read -rp "Your OWN wallet address (Shrike; NOT an exchange deposit address): " ADDR
case "$ADDR" in
  bc1*|1*|3*) : ;;
  *) echo "That doesn't look like a valid address. Aborting."; exit 1 ;;
esac
sed -i "s|^MINER_ADDRESS=.*|MINER_ADDRESS=${ADDR}|" .env
# randomise the local RPC password
sed -i "s|^RPC_PASS=.*|RPC_PASS=$(head -c18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')|" .env

# 3. fast-sync from the chain snapshot (skips days of syncing)
SNAP_URL="${SNAP_URL:-https://TODO-your-snapshot-host/snapshot-latest.tar.zst}"   # TODO
SNAP_SHA="${SNAP_SHA:-}"                                                          # TODO: publish sha256
read -rp "Bootstrap from the chain snapshot for fast sync? [Y/n] " yn
if [ "${yn:-Y}" != "n" ] && [ "${yn:-Y}" != "N" ]; then
  echo "Downloading snapshot (this is the fast bit — no multi-day sync)..."
  docker volume create datum-in-a-box_node-data >/dev/null 2>&1 || true
  curl -fL "$SNAP_URL" -o /tmp/snap.tar.zst
  [ -n "$SNAP_SHA" ] && echo "$SNAP_SHA  /tmp/snap.tar.zst" | sha256sum -c -
  docker run --rm -v datum-in-a-box_node-data:/data -v /tmp:/snap alpine \
    sh -c "apk add --no-cache zstd tar >/dev/null && tar -I zstd -xf /snap/snap.tar.zst -C /data"
  rm -f /tmp/snap.tar.zst
fi

# 4. up
docker compose up -d --build

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
PORT=$(grep '^STRATUM_PORT=' .env | cut -d= -f2)
echo
echo "=================================================================="
echo "  Done. Point your miners at:   ${IP:-<this-machine-ip>}:${PORT}"
echo "     username = your address        password = x"
echo "  Status page:  http://${IP:-<this-machine-ip>}:8000"
echo "=================================================================="
echo "  (Node syncs the last bit in the background; blocks flow once caught up.)"
