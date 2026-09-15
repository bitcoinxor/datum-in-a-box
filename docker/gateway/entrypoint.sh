#!/usr/bin/env sh
set -e
: "${MINER_ADDRESS:?set MINER_ADDRESS in .env}"
export POOL_PORT="${POOL_PORT:-28915}"

# Render gateway.json from the template (envsubst fills ${VARS} from the container env).
mkdir -p /config
envsubst < /gateway.json.tmpl > /config/gateway.json

echo "[entrypoint] gateway.json rendered  ->  pool_host=${POOL_HOST:-<solo>}  address=${MINER_ADDRESS}"

# NOTE: confirm the config flag for your ratum-gateway build (this mirrors the C gateway's -c).
exec ratum-gateway -c /config/gateway.json
