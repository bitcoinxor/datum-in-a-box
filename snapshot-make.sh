#!/usr/bin/env bash
# snapshot-make.sh - build a pruned-chain snapshot from this node and publish it to R2.
# Pauses the node for the tar (about a minute), then restarts it. Weekly via snapshot-make.timer.
set -euo pipefail
set -a; . /etc/xorpool-snapshot.env; set +a
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
  RCLONE_CONFIG_R2_ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" \
  RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true RCLONE_CONFIG_R2_DISABLE_CHECKSUM=true RCLONE_CONFIG_R2_CHUNK_SIZE=64M
DATA=/var/lib/knots; OUT=/var/tmp/snapshot; PUB="https://snapshot.xorpool.com"
CLI="sudo -u knots /usr/local/bin/bitcoin-cli -datadir=$DATA"
KNOTS=$(/usr/local/bin/bitcoind --version | head -1 | grep -oE 'v[0-9.]+knots[0-9]+')
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
trap 'systemctl is-active --quiet knotsd || { log "restarting node after failure"; systemctl start knotsd; }' EXIT

mkdir -p "$OUT"; rm -f "$OUT"/*
info=$($CLI getblockchaininfo)
python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if (not d["initialblockdownload"] and d["verificationprogress"]>0.9999) else 1)' <<<"$info" \
  || { log "node is not at the tip; not snapshotting"; exit 1; }
H=$(python3 -c 'import sys,json; print(json.load(sys.stdin)["blocks"])' <<<"$info")
HASH=$($CLI getblockhash "$H")
F="snapshot-$H.tar.zst"
log "snapshot at height $H ($HASH)"

t0=$(date +%s); systemctl stop knotsd
tar -C "$DATA" -cf - blocks chainstate | zstd -T0 -3 -q -o "$OUT/$F"
systemctl start knotsd; t1=$(date +%s)
log "archive built, node paused $((t1-t0)) s"
for i in $(seq 1 60); do $CLI getblockcount >/dev/null 2>&1 && break; sleep 2; done
log "node back at height $($CLI getblockcount)"

SHA=$(sha256sum "$OUT/$F" | cut -d' ' -f1); SIZE=$(stat -c %s "$OUT/$F")
printf '%s  %s\n' "$SHA" "$F" > "$OUT/$F.sha256"
python3 - "$OUT/latest.json" "$F" "$H" "$HASH" "$SIZE" "$SHA" "$KNOTS" <<'PY'
import sys,json,datetime
p,f,h,bh,size,sha,knots=sys.argv[1:8]
json.dump({"file":f,"url":"https://snapshot.xorpool.com/"+f,"height":int(h),"block_hash":bh,"size_bytes":int(size),"sha256":sha,
           "knots":knots,"prune_mb":2000,"created_utc":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "contents":["blocks/","chainstate/"],"note":"extract into the node datadir with the node stopped; verify sha256 first"},
          open(p,"w"),indent=2)
PY
log "uploading $F ($((SIZE/1048576)) MB) sha256 $SHA"
rclone -q copyto "$OUT/$F" "r2:$R2_BUCKET/$F"
rclone -q copyto "$OUT/$F.sha256" "r2:$R2_BUCKET/$F.sha256"
rclone -q copyto "$OUT/latest.json" "r2:$R2_BUCKET/latest.json"
remote=$(curl -sI --max-time 20 "$PUB/$F" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
[ "$remote" = "$SIZE" ] || { log "PUBLISHED SIZE MISMATCH: remote=$remote local=$SIZE"; exit 1; }
log "published $PUB/$F ($SIZE bytes verified)"
# drop older snapshots
for old in $(rclone lsf "r2:$R2_BUCKET" | grep -E '^snapshot-[0-9]+\.tar\.zst(\.sha256)?$' | grep -v "^$F"); do
  rclone -q deletefile "r2:$R2_BUCKET/$old" && log "removed old $old"
done
rm -f "$OUT"/*
log "done: height $H, $SIZE bytes, $PUB/latest.json"
