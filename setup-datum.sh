#!/usr/bin/env bash
# =====================================================================================
#  Bitcoin Xor - build your own blocks: one-command DATUM setup
#
#  Installs, on this machine, everything needed to mine on the Bitcoin BLAKE2b chain with
#  YOUR OWN block templates:
#     * Bitcoin Knots (BLAKE2b fork) v29.4.1 - pruned full node, RPC local-only
#     * ratum-gateway 0.1.28            - DATUM gateway your ASICs connect to on :23334
#     * Xor Desk (optional)             - a local web dashboard for this machine, sends nothing anywhere
#  and points the gateway at the Bitcoin Xor DATUM pool for the payout split (1% fee).
#
#  It asks a few questions, checks the machine, and never deletes a node's data.
#  Safe to re-run: an existing install is updated in place (your chain data is kept).
#
#  Usage (as root):   sudo bash setup-datum.sh
#  Source: https://github.com/bitcoinxor/datum-in-a-box   Questions: https://t.me/bitcoinxor
# =====================================================================================
set -euo pipefail
# Flags:  --noninteractive   take every answer from /etc/xordesk.json (written by a previous run) - used by Xor Desk
#         --snapshot         with --noninteractive: fetch the chain snapshot if the node is behind it
NONINT=0; WANT_SNAP=0
for a in "$@"; do case "$a" in --noninteractive) NONINT=1;; --snapshot) WANT_SNAP=1;; *) echo "unknown option: $a" >&2; exit 2;; esac; done

SETUP_VERSION="v1.3.0"
KNOTS_VER="29.4.1.knots20260508"
RATUM_VER="0.1.28"
POOL_HOST="datum.xorpool.com"
POOL_PORT="28915"
POOL_PUBKEY="b83aedbba54ba2aa605c76859d97aebd16dece3284402b9fc874778a974da4acbb449f6ccda61625d700036f0487a05f5184f79a07abf2880da77352f4cc487e"
POOL_URL="https://xorpool.com/datum"
SNAPSHOT_URL="https://snapshot.xorpool.com/latest.json"   # pruned chain snapshot to skip the initial sync
PEER1="stratum.xorpool.com:18901"
PEER2="datum.xorpool.com:8333"

SVC_USER="knots"
NODE_DIR="/var/lib/knots"
GW_DIR="/etc/ratum"
GW_CONF="$GW_DIR/gateway.json"
NODE_CONF="$NODE_DIR/bitcoin.conf"
STRATUM_PORT="23334"
MIN_DISK_GB=25

# ---------------------------------------------------------------- helpers
bold=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; grn=$'\e[32m'; yel=$'\e[33m'; off=$'\e[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s  %s%s\n' "${grn}OK${off}" "$*" ""; }
warn() { printf '%sWARNING%s  %s\n' "$yel" "$off" "$*"; }
die()  { ERR_LINE=${BASH_LINENO[0]}; printf '\n%sERROR%s  %s\n' "$red" "$off" "$*" >&2; exit 1; }
ERR_LINE=0; trap 'ERR_LINE=$LINENO' ERR
trap 'rc=$?; if [ $rc -ne 0 ]; then printf "\n%sThe setup stopped at line %s (exit %s).%s Nothing has been deleted; fix the cause and run the script again.\n" "$red" "$ERR_LINE" "$rc" "$off" >&2; fi' EXIT

# Questions come from the terminal even when the script is piped in.
if ( : < /dev/tty ) 2>/dev/null; then IN=/dev/tty; else IN=""; fi   # a tty we can actually open; otherwise answers come from stdin
readline() { if [ "$NONINT" -eq 1 ]; then return 1; fi; if [ -n "$IN" ]; then IFS= read -r "$1" < "$IN"; else IFS= read -r "$1"; fi; }   # never reopen a redirected stdin: that restarts it from line 1
ask() {  # ask VAR "prompt" "default"
  local var="$1" prompt="$2" def="${3:-}" val
  while :; do
    if [ -n "$def" ]; then printf '%s [%s]: ' "$prompt" "$def" >&2; else printf '%s: ' "$prompt" >&2; fi
    readline val || die "no input"
    val="${val:-$def}"
    [ -n "$val" ] && { printf -v "$var" '%s' "$val"; return; }
    say "  (this one is required)" >&2
  done
}
confirm_default_yes() {  # Enter or y = yes
  local a; printf '%s [Y/n]: ' "$1" >&2; readline a || a=""
  case "${a,,}" in n|no) return 1;; *) return 0;; esac
}
confirm() {  # confirm "question" -> returns 0 on y/yes
  local a; printf '%s [y/N]: ' "$1" >&2; readline a || a=""
  case "${a,,}" in y|yes) return 0;; *) return 1;; esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || die "run as root:  sudo bash $0"
. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release - this script supports Ubuntu and Debian"
case "${ID:-}" in ubuntu|debian) ;; *) die "unsupported OS '${ID:-?}' - this script supports Ubuntu 26.04 / 24.04 and Debian 12+";; esac
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  KNOTS_ARCH="x86_64-linux-gnu";  RATUM_ARCH="x86_64-linux-musl" ;;
  aarch64) KNOTS_ARCH="aarch64-linux-gnu"; RATUM_ARCH="aarch64-linux-musl" ;;
  *) die "unsupported CPU architecture '$ARCH' (need x86_64 or aarch64)";;
esac
have systemctl || die "systemd is required"

say ""
say "${bold}Bitcoin Xor - DATUM setup${off}   ${dim}Knots v$KNOTS_VER + ratum-gateway $RATUM_VER on ${PRETTY_NAME:-$ID} ($ARCH)${off}"
say ""

# Machine checks (informative; only disk is a hard stop)
MEM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{printf "%d",$2/1024}' /proc/meminfo)
CPUS=$(nproc)
mkdir -p "$(dirname "$NODE_DIR")"
DISK_GB=$(df -BG --output=avail "$(dirname "$NODE_DIR")" | tail -1 | tr -dc '0-9')
say "Machine: ${CPUS} CPU, ${MEM_MB} MB RAM, ${SWAP_MB} MB swap, ${DISK_GB} GB free for the node"
[ "$DISK_GB" -ge "$MIN_DISK_GB" ] || die "need at least ${MIN_DISK_GB} GB free under $(dirname "$NODE_DIR") (have ${DISK_GB} GB). The pruned node uses ~14 GB plus headroom."
[ "$CPUS" -ge 2 ] || warn "only 1 CPU - it works, but the first sync will be slow"
NEED_SWAP=0
if [ "$MEM_MB" -lt 3500 ] && [ "$SWAP_MB" -lt 1500 ]; then
  warn "less than 4 GB RAM and little swap - a 2 GB swap file will be added so the first sync does not run out of memory"
  NEED_SWAP=1
fi

UPDATE=0
if [ -f "$NODE_CONF" ] || [ -f "$GW_CONF" ]; then
  UPDATE=1
  say ""
  say "An existing install was found. It will be ${bold}updated in place${off}: binaries refreshed, configs rewritten from your answers,"
  say "chain data under $NODE_DIR kept as is."
fi

# ---------------------------------------------------------------- questions
say ""
say "${bold}A few questions${off} (most just need Enter)."
say ""
say "1) Your payout address. Every block you help find pays this address straight from the coinbase."
say "   ${yel}Use a wallet you hold the keys to - NOT an exchange deposit address.${off} Need a wallet? https://xorpool.com/wallet"
OLD_ADDR=""; OLD_NAME=""; OLD_PASS=""; OLD_POOL=""
if [ "$UPDATE" -eq 1 ] && [ -f "$GW_CONF" ] && have python3; then
  OLD_ADDR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mining"].get("pool_address",""))' "$GW_CONF" 2>/dev/null || true)
  OLD_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mining"].get("coinbase_tag_secondary",""))' "$GW_CONF" 2>/dev/null || true)
  OLD_POOL=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["datum"]; print("%s:%s" % (d.get("pool_host",""), d.get("pool_port","")))' "$GW_CONF" 2>/dev/null || true)
fi
if [ -f "$NODE_CONF" ]; then OLD_PASS=$(sed -n 's/^rpcpassword=//p' "$NODE_CONF" | head -1); fi

validate_address() {  # exact checksum validation for bc1q/bc1p (bech32/bech32m) and 1.../3... (base58check)
  python3 - "$1" <<'PY'
import sys
a=sys.argv[1].strip()
CH="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def polymod(v):
    G=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; c=1
    for x in v:
        b=c>>25; c=((c&0x1ffffff)<<5)^x
        for i in range(5):
            if (b>>i)&1: c^=G[i]
    return c
def bech(a):
    if a!=a.lower() and a!=a.upper(): return False
    a=a.lower(); p=a.rfind('1')
    if p<1 or p+7>len(a) or a[:p]!="bc": return False
    data=[CH.find(c) for c in a[p+1:]]
    if -1 in data: return False
    hrp=[ord(c)>>5 for c in "bc"]+[0]+[ord(c)&31 for c in "bc"]
    pm=polymod(hrp+data); v=data[0]
    if v==0 and pm!=1: return False
    if v>0 and pm!=0x2bc830a3: return False
    acc=bits=0; out=[]
    for d in data[1:-6]:
        acc=(acc<<5)|d; bits+=5
        while bits>=8: bits-=8; out.append((acc>>bits)&255)
    n=len(out)
    return (v==0 and n in (20,32)) or (v==1 and n==32)
def b58(a):
    import hashlib
    A="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; n=0
    for c in a:
        if c not in A: return False
        n=n*58+A.index(c)
    pad=len(a)-len(a.lstrip("1")); raw=b"\0"*pad+n.to_bytes((n.bit_length()+7)//8,"big")
    if len(raw)!=25 or raw[0] not in (0,5): return False
    return hashlib.sha256(hashlib.sha256(raw[:21]).digest()).digest()[:4]==raw[21:]
ok = bech(a) if a.lower().startswith("bc1") else b58(a) if a[:1] in "13" else False
sys.exit(0 if ok else 1)
PY
}

have python3 || { say "installing python3 (used to check the address)..."; apt-get -qq update && apt-get -qq -y install python3 >/dev/null; }
if [ "$NONINT" -eq 1 ]; then
  [ -f /etc/xordesk.json ] || die "--noninteractive needs /etc/xordesk.json from a previous run"
  eval "$(python3 -c 'import json; d=json.load(open("/etc/xordesk.json")); import shlex
print("ADDR=%s NAME=%s POOL=%s DESK_LISTEN=%s" % (shlex.quote(d.get("address","")), shlex.quote(d.get("name","")), shlex.quote(d.get("pool","")), shlex.quote(d.get("listen","127.0.0.1"))))')"
  validate_address "$ADDR" || die "saved payout address is not valid: $ADDR"
  [ "${#NAME}" -le 60 ] && printf '%s' "$NAME" | LC_ALL=C grep -qE '^[A-Za-z0-9 ._-]+$' || die "saved block name is not valid"
  case "$POOL" in *:*) POOL_HOST="${POOL%%:*}"; POOL_PORT="${POOL##*:}";; esac
  say ""; say "${bold}Non-interactive run${off} with the saved answers: $ADDR / $NAME / $POOL_HOST:$POOL_PORT"
fi
while [ "$NONINT" -eq 0 ]; do
  ask ADDR "   Payout address" "$OLD_ADDR"
  ADDR="${ADDR//[[:space:]]/}"
  if validate_address "$ADDR"; then ok "address checks out"; break; fi
  say "   ${red}That is not a valid address on this chain${off} (must be bc1q..., bc1p..., 1... or 3..., typed exactly). Try again."
done

say ""
say "2) A name for your blocks. It is written into every block you help find, next to 'Bitcoin Xor', on-chain forever."
say "   Letters, numbers, spaces and simple punctuation; up to 60 characters."
while [ "$NONINT" -eq 0 ]; do
  ask NAME "   Your name / tag" "$OLD_NAME"
  NAME="$(printf '%s' "$NAME" | tr -d '\r\n\t' | sed 's/^ *//; s/ *$//')"
  if [ "${#NAME}" -le 60 ] && printf '%s' "$NAME" | LC_ALL=C grep -qE '^[A-Za-z0-9 ._-]+$'; then ok "tag: $NAME"; break; fi
  say "   ${red}Keep it to letters, numbers, spaces . _ -  and at most 60 characters.${off}"
done

say ""
say "3) Which pool endpoint to send shares to. Press Enter for the default. If this machine is in Asia or Europe you can use"
say "   hk.datum.xorpool.com:28915 or eu.datum.xorpool.com:28915 instead - same pool, same payout, just closer."
while [ "$NONINT" -eq 0 ]; do
  ask POOL "   DATUM pool (host:port)" "${OLD_POOL:-$POOL_HOST:$POOL_PORT}"
  POOL="${POOL//[[:space:]]/}"; POOL="${POOL#*://}"
  case "$POOL" in *:*) H="${POOL%%:*}"; P="${POOL##*:}";; *) H="$POOL"; P="$POOL_PORT";; esac
  if printf '%s' "$H" | LC_ALL=C grep -qE '^[A-Za-z0-9.-]+$' && printf '%s' "$P" | grep -qE '^[0-9]{1,5}$' && [ "$P" -ge 1 ] && [ "$P" -le 65535 ]; then
    if getent hosts "$H" >/dev/null 2>&1; then POOL_HOST="$H"; POOL_PORT="$P"; ok "pool: $POOL_HOST:$POOL_PORT"; break; fi
    say "   ${red}Cannot resolve host '$H'${off} - check the spelling."; continue
  fi
  say "   ${red}Give it as host:port${off}, e.g. datum.xorpool.com:28915"
done

SNAP=0; SNAP_H=""; SNAP_HASH=""; SNAP_SHA=""; SNAP_FILE=""; SNAP_SIZE=0
if latest=$(curl -fsS --max-time 15 "$SNAPSHOT_URL" 2>/dev/null); then
  read -r SNAP_FILE SNAP_H SNAP_HASH SNAP_SHA SNAP_SIZE <<<"$(python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["file"],d["height"],d["block_hash"],d["sha256"],d["size_bytes"])' <<<"$latest" 2>/dev/null || true)"
fi
if [ -n "$SNAP_FILE" ]; then
  have_h=0; [ -d "$NODE_DIR/chainstate" ] && have_h=$(sudo -u "$SVC_USER" /usr/local/bin/bitcoin-cli -datadir="$NODE_DIR" getblockcount 2>/dev/null || echo 0)
  if [ "${have_h:-0}" -ge "$SNAP_H" ]; then
    say ""; say "Your node is already past the published snapshot (height $have_h); no snapshot needed."
  elif [ "$DISK_GB" -lt 35 ]; then
    say ""; warn "the chain snapshot needs ~35 GB free during install (have ${DISK_GB} GB) - skipping it; the node will sync from scratch (1-3 days)"
  else
    say ""
    say "4) Skip the initial sync? A snapshot of the pruned chain at height $SNAP_H ($((SNAP_SIZE/1073741824)) GB download) is available."
    say "   With it the node starts at the tip in minutes instead of 1-3 days. You trust this copy of history up to"
    say "   height $SNAP_H (like any bootstrap); every block after it is verified by your own node."
    if [ "$NONINT" -eq 1 ]; then SNAP=$WANT_SNAP; [ "$SNAP" -eq 1 ] && ok "snapshot: height $SNAP_H (requested)"
    elif confirm_default_yes "   Download the snapshot?"; then SNAP=1; ok "snapshot: height $SNAP_H"; else say "   ok - syncing from scratch"; fi
  fi
fi

DESK=0; DESK_LISTEN="127.0.0.1"
OLD_DESK=0; [ -f /etc/xordesk.json ] && OLD_DESK=1
say ""
say "5) Xor Desk (beta): a small web dashboard that runs on this machine - node sync, gateway, rigs, settings, one-click"
say "   update/snapshot/restart, logs. It binds to this machine only and sends nothing anywhere."
if [ "$OLD_DESK" -eq 1 ]; then say "   (already installed - it will be updated)"; fi
if [ "$NONINT" -eq 1 ]; then DESK=1; ok "Xor Desk: keep ($( [ "$DESK_LISTEN" = "0.0.0.0" ] && echo LAN || echo "this machine only" ))"
elif confirm_default_yes "   Install Xor Desk?"; then
  DESK=1
  # a private (RFC1918) address means this box is on a LAN behind NAT: offer LAN access; a public IP stays localhost-only
  MYIP4=$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  if printf '%s' "$MYIP4" | grep -qE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; then
    if confirm_default_yes "   This machine has a LAN address ($MYIP4). Make Xor Desk reachable from other devices on your LAN?"; then DESK_LISTEN="0.0.0.0"; fi
  fi
  ok "Xor Desk: yes ($( [ "$DESK_LISTEN" = "0.0.0.0" ] && echo "LAN" || echo "this machine only" ))"
else say "   ok - skipping Xor Desk (re-run the script any time to add it)"; fi

if [ -n "$OLD_PASS" ]; then RPC_PASS="$OLD_PASS"; else RPC_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(20))')"; fi

say ""
say "${bold}Summary${off}"
say "  Payout address   $ADDR"
say "  Block tag        Bitcoin Xor / $NAME"
say "  Pool             $POOL_HOST:$POOL_PORT  (1% fee, you build the templates)"
say "  Node             $NODE_DIR  (pruned, ~14 GB, RPC local-only)"
[ "$SNAP" -eq 1 ] && say "  Snapshot         $SNAP_FILE -> node starts at height $SNAP_H"
[ "$DESK" -eq 1 ] && say "  Xor Desk         http://$( [ "$DESK_LISTEN" = "0.0.0.0" ] && echo "${MYIP4:-this-machine}" || echo 127.0.0.1 ):8090  (password shown at the end)"
[ "$NEED_SWAP" -eq 1 ] && say "  Swap             add a 2 GB /swapfile"
say ""
if [ "$NONINT" -eq 0 ]; then confirm "Install with these settings?" || { say "Nothing changed."; trap - EXIT; exit 0; }; fi

# ---------------------------------------------------------------- install
say ""
say "${bold}Installing...${off}"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update
apt-get -qq -y install curl ca-certificates python3 zstd >/dev/null
ok "packages"

if [ "$NEED_SWAP" -eq 1 ] && [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "2 GB swap"
fi

id "$SVC_USER" >/dev/null 2>&1 || useradd -r -m -d "$NODE_DIR" -s /usr/sbin/nologin "$SVC_USER"
mkdir -p "$NODE_DIR" "$GW_DIR"; chown "$SVC_USER:$SVC_USER" "$NODE_DIR"
ok "service user '$SVC_USER'"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
cd "$TMP"
KURL="https://github.com/bitcoinknots/bitcoin/releases/download/v$KNOTS_VER"
KTAR="bitcoin-$KNOTS_VER-$KNOTS_ARCH.tar.gz"
if [ "$(/usr/local/bin/bitcoind --version 2>/dev/null | head -1 | grep -o 'v[0-9.]*knots[0-9]*' || true)" = "v$KNOTS_VER" ]; then
  ok "Bitcoin Knots v$KNOTS_VER already installed"
else
  say "downloading Bitcoin Knots v$KNOTS_VER (~55 MB)..."
  curl -fsSLo "$KTAR" "$KURL/$KTAR" || die "download failed: $KURL/$KTAR"
  curl -fsSLo SHA256SUMS "$KURL/SHA256SUMS" || die "download failed: SHA256SUMS"
  sha256sum --ignore-missing --quiet -c SHA256SUMS || die "checksum MISMATCH on $KTAR - not installing it"
  tar xzf "$KTAR"
  install -m 755 "bitcoin-$KNOTS_VER/bin/bitcoind" "bitcoin-$KNOTS_VER/bin/bitcoin-cli" /usr/local/bin/
  ok "$(/usr/local/bin/bitcoind --version | head -1)"
fi

RURL="https://github.com/iohzrd/ratum/releases/download/v$RATUM_VER"
RTAR="ratum-gateway-$RATUM_VER-$RATUM_ARCH.tar.gz"
if /usr/local/bin/ratum-gateway --version 2>/dev/null | grep -q " $RATUM_VER "; then
  ok "ratum-gateway $RATUM_VER already installed"
else
  say "downloading ratum-gateway $RATUM_VER (~3 MB)..."
  curl -fsSLo "$RTAR" "$RURL/$RTAR" || die "download failed: $RURL/$RTAR"
  curl -fsSLo "$RTAR.sha256" "$RURL/$RTAR.sha256" || die "download failed: $RTAR.sha256"
  # the .sha256 file may name the file with or without a path; compare the digest itself
  [ "$(sha256sum "$RTAR" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$RTAR.sha256")" ] || die "checksum MISMATCH on $RTAR - not installing it"
  tar xzf "$RTAR"
  BIN=$(find . -type f -name ratum-gateway | head -1); [ -n "$BIN" ] || die "ratum-gateway binary not found in the archive"
  install -m 755 "$BIN" /usr/local/bin/ratum-gateway
  ok "$(/usr/local/bin/ratum-gateway --version 2>&1 | head -1)"
fi
cd /

# node config - the chain data (if any) is untouched
cat > "$NODE_CONF" <<EOF
# Bitcoin Knots (BLAKE2b fork) - written by setup-datum.sh on $(date -u +%Y-%m-%d)
server=1
disablewallet=1
prune=2000
txindex=0
dbcache=$([ "$MEM_MB" -ge 3500 ] && echo 2000 || echo 600)
maxmempool=200
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcuser=knots
rpcpassword=$RPC_PASS
dnsseed=0
fixedseeds=0
addnode=$PEER1
addnode=$PEER2
blocknotify=/usr/bin/pkill -USR1 ratum-gateway
EOF
chown "$SVC_USER:$SVC_USER" "$NODE_CONF"; chmod 600 "$NODE_CONF"
ok "node config $NODE_CONF"

# gateway config - written with python so the name is JSON-escaped correctly
GW_API_PASS=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["api"].get("admin_password",""))
except Exception: print("")' "$GW_CONF" 2>/dev/null)
[ -n "$GW_API_PASS" ] || GW_API_PASS="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
python3 - "$GW_CONF" "$RPC_PASS" "$ADDR" "$NAME" "$GW_API_PASS" <<PY
import json,sys
p,pw,addr,name,apipw=sys.argv[1:6]
cfg={
 "bitcoind":{"rpcurl":"http://127.0.0.1:8332","rpcuser":"knots","rpcpassword":pw,"work_update_seconds":40,"notify_fallback":True},
 "mining":{"pool_address":addr,"coinbase_tag_primary":name,"coinbase_tag_secondary":name},
 "stratum":{"listen_addr":"0.0.0.0","listen_port":$STRATUM_PORT},
 "datum":{"pool_host":"$POOL_HOST","pool_port":$POOL_PORT,"pool_pubkey":"$POOL_PUBKEY","pool_url":"$POOL_URL",
          "pool_pass_full_users":False,"pool_pass_workers":True,"gateway_fee_bps":0,"pooled_mining_only":True},
 "api":{"listen_addr":"127.0.0.1","listen_port":8000,"admin_password":apipw}}
json.dump(cfg,open(p,"w"),indent=2); open(p,"a").write("\n")
PY
chown -R "$SVC_USER:$SVC_USER" "$GW_DIR"; chmod 640 "$GW_CONF"
ok "gateway config $GW_CONF"

cat > /etc/systemd/system/knotsd.service <<EOF
[Unit]
Description=Bitcoin Knots (BLAKE2b fork, pruned)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
ExecStart=/usr/local/bin/bitcoind -datadir=$NODE_DIR -conf=$NODE_CONF
Restart=on-failure
RestartSec=5
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/ratum-gateway.service <<EOF
[Unit]
Description=ratum-gateway (DATUM, stratum $STRATUM_PORT)
After=network-online.target knotsd.service
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
ExecStart=/usr/local/bin/ratum-gateway -c $GW_CONF
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
ok "services"

# Xor Desk (optional): fetch the app from the same release as this script, write its config, run it as a service
DESK_PASS=""
if [ "$DESK" -eq 1 ]; then
  mkdir -p /opt/xordesk /var/log/xordesk
  DESK_OK=1
  if curl -fsSLo /opt/xordesk/xordesk.py.new "https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/$SETUP_VERSION/xordesk/xordesk.py" \
     && curl -fsSLo /etc/systemd/system/xordesk.service.new "https://raw.githubusercontent.com/bitcoinxor/datum-in-a-box/$SETUP_VERSION/xordesk/xordesk.service" \
     && python3 -m py_compile /opt/xordesk/xordesk.py.new; then
    mv -f /opt/xordesk/xordesk.py.new /opt/xordesk/xordesk.py; mv -f /etc/systemd/system/xordesk.service.new /etc/systemd/system/xordesk.service
  else
    rm -f /opt/xordesk/xordesk.py.new /etc/systemd/system/xordesk.service.new
    if [ -f /opt/xordesk/xordesk.py ]; then warn "could not download the Xor Desk update; keeping the installed copy"
    else warn "could not download Xor Desk; skipping it (the node and gateway are unaffected - re-run later to add it)"; DESK_OK=0; fi
  fi
fi
if [ "$DESK" -eq 1 ] && [ "$DESK_OK" -eq 1 ]; then
  OLD_HASH=""; OLD_SALT=""
  if [ -f /etc/xordesk.json ]; then
    OLD_HASH=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("password_sha256",""))' /etc/xordesk.json 2>/dev/null)
    OLD_SALT=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("salt",""))' /etc/xordesk.json 2>/dev/null)
  fi
  if [ -n "$OLD_HASH" ]; then SALT="$OLD_SALT"; HASH="$OLD_HASH"
  else DESK_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(9))'); SALT=$(python3 -c 'import secrets; print(secrets.token_hex(8))'); HASH=$(printf '%s%s' "$SALT" "$DESK_PASS" | sha256sum | cut -d' ' -f1); fi
  python3 - /etc/xordesk.json "$DESK_LISTEN" "$SALT" "$HASH" "$SETUP_VERSION" "$ADDR" "$NAME" "$POOL_HOST:$POOL_PORT" <<PY
import json,sys
p,listen,salt,h,tag,addr,name,pool=sys.argv[1:9]
json.dump({"port":8090,"listen":listen,"salt":salt,"password_sha256":h,"installer_tag":tag,"address":addr,"name":name,"pool":pool},open(p,"w"),indent=2)
PY
  chmod 600 /etc/xordesk.json
  systemctl daemon-reload; systemctl enable --now xordesk >/dev/null 2>&1; systemctl restart xordesk
  ok "Xor Desk"
fi

# a small status helper
cat > /usr/local/bin/datum-status <<'EOF'
#!/usr/bin/env bash
# Shows node sync progress and gateway state in plain words.
c="sudo -u knots /usr/local/bin/bitcoin-cli -datadir=/var/lib/knots -conf=/var/lib/knots/bitcoin.conf"
echo "node:     $(systemctl is-active knotsd)    gateway: $(systemctl is-active ratum-gateway)"
synced=0
if info=$($c getblockchaininfo 2>/dev/null); then
  line=$(echo "$info" | python3 -c 'import sys,json; d=json.load(sys.stdin); p=d["verificationprogress"]*100; print(("chain:    height %d  at tip" % d["blocks"]) if p>99.99 else ("chain:    height %d  syncing %.2f%%" % (d["blocks"], p)))')
  echo "$line"; case "$line" in *"at tip"*) synced=1;; esac
else echo "chain:    node starting / not answering RPC yet"; fi
echo "peers:    $($c getconnectioncount 2>/dev/null || echo ?)"
if [ "$synced" -eq 0 ]; then
  echo "gateway:  waiting for the node to finish syncing (expected - your miners get work automatically once it is at the tip)"
else
  curl -s -m 3 http://127.0.0.1:8000/stats.json | python3 -c '
import sys,json
d=json.load(sys.stdin); h=d.get("hashrate") or {}
hist=h.get("history") or []; hs=hist[-1][1] if hist and len(hist[-1])>1 else 0
def cnt(x): return x.get("count",x) if isinstance(x,dict) else x
print("gateway:  %.2f TH/s   shares accepted %s   rejected %s" % (hs/1e12, cnt(d.get("shares_accepted",0)), cnt(d.get("shares_rejected",0))))' 2>/dev/null || echo "gateway:  not answering yet"
  echo "last log: $(journalctl -u ratum-gateway -n 1 --no-pager -o cat 2>/dev/null)"
fi
EOF
chmod 755 /usr/local/bin/datum-status

systemctl enable --now knotsd >/dev/null 2>&1
systemctl enable --now ratum-gateway >/dev/null 2>&1
sleep 4
systemctl is-active --quiet knotsd || die "the node did not start - see: journalctl -u knotsd -n 50"
systemctl is-active --quiet ratum-gateway || die "the gateway did not start - see: journalctl -u ratum-gateway -n 50"

if [ "$SNAP" -eq 1 ]; then
  say ""; say "${bold}Downloading the chain snapshot${off} ($((SNAP_SIZE/1073741824)) GB) - this is the long part, a few minutes on a good link..."
  SNAP_DIR=/var/tmp/xorpool-snapshot; mkdir -p "$SNAP_DIR"
  curl -fL -# --retry 5 --retry-delay 5 -C - -o "$SNAP_DIR/$SNAP_FILE" "https://snapshot.xorpool.com/$SNAP_FILE" || die "snapshot download failed - run the script again to resume it"
  say "verifying checksum..."
  [ "$(sha256sum "$SNAP_DIR/$SNAP_FILE" | cut -d' ' -f1)" = "$SNAP_SHA" ] || { rm -f "$SNAP_DIR/$SNAP_FILE"; die "snapshot checksum MISMATCH - not using it. Run the script again to re-download."; }
  ok "checksum matches"
  systemctl stop knotsd
  rm -rf "$NODE_DIR/blocks" "$NODE_DIR/chainstate"      # only the chain data; the config and everything else stay
  tar -C "$NODE_DIR" --use-compress-program=unzstd -xf "$SNAP_DIR/$SNAP_FILE" || die "snapshot extract failed"
  chown -R "$SVC_USER:$SVC_USER" "$NODE_DIR/blocks" "$NODE_DIR/chainstate"
  rm -f "$SNAP_DIR/$SNAP_FILE"
  systemctl start knotsd
  for i in $(seq 1 90); do got=$(sudo -u "$SVC_USER" /usr/local/bin/bitcoin-cli -datadir="$NODE_DIR" getblockhash "$SNAP_H" 2>/dev/null) && break; sleep 2; done
  if [ "${got:-}" = "$SNAP_HASH" ]; then ok "node started from the snapshot at height $SNAP_H; block hash verified"
  else warn "could not verify block $SNAP_H against the published hash yet (node still starting?) - check later with: datum-status"; fi
fi
trap - EXIT
MYIP=$(ip -o -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

say ""
say "${grn}${bold}Done.${off}"
say ""
say "  Point your ASICs at:   ${bold}stratum+tcp://${MYIP:-<this-machine-ip>}:$STRATUM_PORT${off}"
say "                         worker:  ${bold}anything.rig1${off}   password:  ${bold}x${off}"
say ""
if [ "$SNAP" -eq 1 ]; then
  say "  The node started from the snapshot and is catching up the last few blocks - your ASICs get work within minutes."
  say ""
elif [ "$UPDATE" -eq 0 ]; then
  say "  The node is now syncing the chain from the start - ${bold}1 to 3 days${off} on a small VPS. Your ASICs will get"
  say "  work automatically the moment it reaches the tip; until then the gateway waits. Leave it running."
  say "  (Re-run this script and answer Y to the snapshot question to skip most of the wait.)"
  say ""
fi
say "  The gateway listens on port $STRATUM_PORT. If this machine or your provider has a firewall, allow that port from your miners."
say ""
if [ "$DESK" -eq 1 ]; then
  if [ "$DESK_LISTEN" = "0.0.0.0" ]; then say "  Xor Desk (from any device on your LAN):  ${bold}http://${MYIP4:-this-machine}:8090${off}"
  else say "  Xor Desk (this machine only; from elsewhere open an SSH tunnel first:  ssh -L 8090:127.0.0.1:8090 you@this-machine):"; say "                         ${bold}http://127.0.0.1:8090${off}"; fi
  if [ -n "$DESK_PASS" ]; then say "  Xor Desk password:     ${bold}$DESK_PASS${off}   (shown once - write it down; re-run the script to keep it, or delete /etc/xordesk.json to get a new one)"; fi
  say ""
fi
say "  Check on it any time:  ${bold}datum-status${off}"
say "  Your stats once shares flow:  $POOL_URL/miner/$ADDR"
say "  Logs:  journalctl -u knotsd -f     journalctl -u ratum-gateway -f"
say ""
datum-status || true
