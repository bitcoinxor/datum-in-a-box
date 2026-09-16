#!/bin/bash
# =====================================================================================
#  Bitcoin Xor - build your own blocks: one-command DATUM setup for macOS
#
#  Installs, on this Mac, everything needed to mine on the Bitcoin BLAKE2b chain with
#  YOUR OWN block templates:
#     * Bitcoin Knots (BLAKE2b fork) v29.4.1 - pruned full node, RPC local-only
#     * ratum-gateway 0.1.28            - DATUM gateway your ASICs connect to on :23334
#  and points the gateway at the Bitcoin Xor DATUM pool for the payout split (1% fee).
#
#  Both run as launchd system services (start at boot, no login needed) under
#  /usr/local/xordatum. Nothing else on the Mac is touched. Xor Desk (the optional
#  dashboard) is Linux-only for now.
#
#  It asks a few questions, checks the machine, and never deletes a node's data.
#  Safe to re-run: an existing install is updated in place (your chain data is kept).
#
#  Usage:   sudo bash setup-datum-macos.sh
#  Source: https://github.com/bitcoinxor/datum-in-a-box   Questions: https://t.me/bitcoinxor
#
#  Written for the bash 3.2 that ships with macOS (no bash-4 features) and for a stock
#  Mac: no Homebrew, no Xcode tools, no python needed (perl and shasum ship with macOS).
# =====================================================================================
set -euo pipefail

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

ROOT="/usr/local/xordatum"
BIN="$ROOT/bin"
NODE_DIR="$ROOT/node"
GW_DIR="$ROOT/gateway"
LOGS="$ROOT/logs"
GW_CONF="$GW_DIR/gateway.json"
NODE_CONF="$NODE_DIR/bitcoin.conf"
NODE_LABEL="com.bitcoinxor.knotsd"
GW_LABEL="com.bitcoinxor.ratum-gateway"
NODE_PLIST="/Library/LaunchDaemons/$NODE_LABEL.plist"
GW_PLIST="/Library/LaunchDaemons/$GW_LABEL.plist"
STRATUM_PORT="23334"
MIN_DISK_GB=25

# ---------------------------------------------------------------- helpers
bold=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; grn=$'\e[32m'; yel=$'\e[33m'; off=$'\e[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s  %s\n' "${grn}OK${off}" "$*"; }
warn() { printf '%sWARNING%s  %s\n' "$yel" "$off" "$*"; }
die()  { ERR_LINE=${BASH_LINENO[0]}; printf '\n%sERROR%s  %s\n' "$red" "$off" "$*" >&2; exit 1; }
ERR_LINE=0; trap 'ERR_LINE=$LINENO' ERR
trap 'rc=$?; if [ $rc -ne 0 ]; then printf "\n%sThe setup stopped at line %s (exit %s).%s Nothing has been deleted; fix the cause and run the script again.\n" "$red" "$ERR_LINE" "$rc" "$off" >&2; fi' EXIT

# Questions come from the terminal even when the script is piped in.
if ( : < /dev/tty ) 2>/dev/null; then IN=/dev/tty; else IN=""; fi
readline() { if [ -n "$IN" ]; then IFS= read -r "$1" < "$IN"; else IFS= read -r "$1"; fi; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
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
confirm_default_yes() { local a; printf '%s [Y/n]: ' "$1" >&2; readline a || a=""; case "$(lower "$a")" in n|no) return 1;; *) return 0;; esac; }
confirm()             { local a; printf '%s [y/N]: ' "$1" >&2; readline a || a=""; case "$(lower "$a")" in y|yes) return 0;; *) return 1;; esac; }
have() { command -v "$1" >/dev/null 2>&1; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
json_get() {  # json_get FILE KEY.PATH  (dotted path, e.g. mining.pool_address) - perl's JSON::PP ships with macOS
  perl -MJSON::PP -e '
    local $/; open(my $f, "<", $ARGV[0]) or exit 1; my $d = decode_json(<$f>);
    for my $k (split /\./, $ARGV[1]) { $d = ref($d) eq "HASH" ? $d->{$k} : undef; last unless defined $d }
    print defined $d ? $d : ""' "$1" "$2" 2>/dev/null || true
}
svc_running() { launchctl print "system/$1" 2>/dev/null | grep -q 'state = running'; }
svc_stop() {  # unload the service; launchd sends SIGTERM and waits ExitTimeOut before SIGKILL
  launchctl bootout "system/$1" >/dev/null 2>&1 || true
}
svc_start() { launchctl bootstrap system "$2" >/dev/null 2>&1 || launchctl kickstart -k "system/$1" >/dev/null 2>&1 || true; }
stop_all() {
  # gateway first (stateless); then the node, and WAIT for it: a killed node has not flushed its chainstate
  # and rewinds + replays on the next start (minutes to hours). ExitTimeOut in the plist gives it 180 s.
  svc_stop "$GW_LABEL"; pkill -x ratum-gateway 2>/dev/null || true
  if pgrep -x bitcoind >/dev/null 2>&1; then
    say "  waiting for the node to shut down cleanly..."
    svc_stop "$NODE_LABEL"
    local i; for i in $(seq 1 180); do pgrep -x bitcoind >/dev/null 2>&1 || break; sleep 1; done
    pkill -TERM -x bitcoind 2>/dev/null || true; sleep 2
  else svc_stop "$NODE_LABEL"; fi
}

# ---------------------------------------------------------------- preflight
[ "$(uname -s)" = "Darwin" ] || die "this is the macOS script; on Linux use setup-datum.sh, on Windows setup-datum.ps1"
[ "$(id -u)" -eq 0 ] || die "run it with sudo:  sudo bash $0"
SVC_USER="${SUDO_USER:-root}"; [ "$SVC_USER" != "root" ] || warn "no sudo user found - the services will run as root (fine, but run the script with sudo from your own account next time)"
OSVER="$(sw_vers -productVersion 2>/dev/null || echo '?')"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  KNOTS_ARCH="arm64-apple-darwin";  RATUM_ARCH="aarch64-macos" ;;
  x86_64) KNOTS_ARCH="x86_64-apple-darwin"; RATUM_ARCH="x86_64-macos" ;;
  *) die "unsupported CPU architecture '$ARCH' (need arm64 or x86_64)";;
esac
have perl || die "perl is missing (it ships with macOS - this is not a stock Mac?)"
have shasum || die "shasum is missing (it ships with macOS)"
have curl || die "curl is missing (it ships with macOS)"
have launchctl || die "launchctl is missing"

say ""
say "${bold}Bitcoin Xor - DATUM setup for macOS${off}   ${dim}Knots v$KNOTS_VER + ratum-gateway $RATUM_VER on macOS $OSVER ($ARCH)${off}"
say ""

MEM_MB=$(( $(sysctl -n hw.memsize) / 1048576 ))
CPUS=$(sysctl -n hw.ncpu)
mkdir -p "$ROOT"
DISK_GB=$(df -g "$ROOT" | tail -1 | awk '{print $4}')
say "Machine: ${CPUS} CPU, ${MEM_MB} MB RAM, ${DISK_GB} GB free for the node"
[ "$DISK_GB" -ge "$MIN_DISK_GB" ] || die "need at least ${MIN_DISK_GB} GB free on this disk (have ${DISK_GB} GB). The pruned node uses ~14 GB plus headroom."

# zstd for the snapshot: Apple's tar can read .zst only if it was built with libzstd (recent macOS), else Homebrew's zstd
ZSTD=""
if tar --zstd -cf /dev/null /dev/null 2>/dev/null; then ZSTD="tar"
elif have zstd; then ZSTD="$(command -v zstd)"
elif [ -x /opt/homebrew/bin/zstd ]; then ZSTD=/opt/homebrew/bin/zstd
elif [ -x /usr/local/bin/zstd ]; then ZSTD=/usr/local/bin/zstd; fi

UPDATE=0
if [ -f "$NODE_CONF" ] || [ -f "$GW_CONF" ]; then
  UPDATE=1
  say ""
  say "An existing install was found in $ROOT. It will be ${bold}updated in place${off}: binaries refreshed, configs rewritten"
  say "from your answers, chain data under $NODE_DIR kept as is."
fi

# ---------------------------------------------------------------- questions
say ""
say "${bold}A few questions${off} (most just need Enter)."
say ""
say "1) Your payout address. Every block you help find pays this address straight from the coinbase."
say "   ${yel}Use a wallet you hold the keys to - NOT an exchange deposit address.${off} Need a wallet? https://xorpool.com/wallet"
OLD_ADDR=""; OLD_NAME=""; OLD_PASS=""; OLD_POOL=""
if [ "$UPDATE" -eq 1 ] && [ -f "$GW_CONF" ]; then
  OLD_ADDR=$(json_get "$GW_CONF" mining.pool_address)
  OLD_NAME=$(json_get "$GW_CONF" mining.coinbase_tag_secondary)
  oh=$(json_get "$GW_CONF" datum.pool_host); op=$(json_get "$GW_CONF" datum.pool_port)
  [ -n "$oh" ] && OLD_POOL="$oh:$op"
fi
if [ -f "$NODE_CONF" ]; then OLD_PASS=$(sed -n 's/^rpcpassword=//p' "$NODE_CONF" | head -1); fi

validate_address() {  # exact checksum validation for bc1q/bc1p (bech32/bech32m) and 1.../3... (base58check), in perl (ships with macOS)
  perl - "$1" <<'PL'
use strict; use warnings; use Digest::SHA qw(sha256); use Math::BigInt;
my $a = $ARGV[0]; $a =~ s/^\s+|\s+$//g;
my $CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
sub polymod { my @G = (0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3); my $c = 1;
  for my $x (@_) { my $b = $c >> 25; $c = (($c & 0x1ffffff) << 5) ^ $x; for my $i (0..4) { $c ^= $G[$i] if ($b >> $i) & 1 } } return $c }
sub bech { my $a = shift; return 0 if $a ne lc($a) && $a ne uc($a); $a = lc $a; my $p = rindex($a, "1");
  return 0 if $p < 1 || $p + 7 > length($a) || substr($a, 0, $p) ne "bc";
  my @data = map { index($CH, $_) } split //, substr($a, $p + 1); return 0 if grep { $_ < 0 } @data;
  my @hrp = ((map { ord($_) >> 5 } split //, "bc"), 0, (map { ord($_) & 31 } split //, "bc"));
  my $pm = polymod(@hrp, @data); my $v = $data[0];
  return 0 if $v == 0 && $pm != 1; return 0 if $v > 0 && $pm != 0x2bc830a3;
  my ($acc, $bits, $n) = (0, 0, 0);
  for my $d (@data[1 .. $#data - 6]) { $acc = ($acc << 5) | $d; $bits += 5; while ($bits >= 8) { $bits -= 8; $n++ } }
  return ($v == 0 && ($n == 20 || $n == 32)) || ($v == 1 && $n == 32) ? 1 : 0 }
sub b58 { my $a = shift; my $A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; my $n = Math::BigInt->new(0);
  for my $c (split //, $a) { my $i = index($A, $c); return 0 if $i < 0; $n = $n * 58 + $i }
  (my $pad = $a) =~ s/[^1].*//; my $hex = $n->as_hex; $hex =~ s/^0x//; $hex = "0$hex" if length($hex) % 2;
  my $raw = ("\0" x length($pad)) . pack("H*", $hex); return 0 if length($raw) != 25; my $ver = ord(substr($raw, 0, 1)); return 0 if $ver != 0 && $ver != 5;
  return substr(sha256(sha256(substr($raw, 0, 21))), 0, 4) eq substr($raw, 21) ? 1 : 0 }
my $ok = (lc($a) =~ /^bc1/) ? bech($a) : ($a =~ /^[13]/) ? b58($a) : 0;
exit($ok ? 0 : 1);
PL
}

while :; do
  ask ADDR "   Payout address" "$OLD_ADDR"
  ADDR="$(printf '%s' "$ADDR" | tr -d '[:space:]')"
  if validate_address "$ADDR"; then ok "address checks out"; break; fi
  say "   ${red}That is not a valid address on this chain${off} (must be bc1q..., bc1p..., 1... or 3..., typed exactly). Try again."
done

say ""
say "2) A name for your blocks. It is written into every block you help find, next to 'Bitcoin Xor', on-chain forever."
say "   Letters, numbers, spaces and simple punctuation; up to 60 characters."
while :; do
  ask NAME "   Your name / tag" "$OLD_NAME"
  NAME="$(printf '%s' "$NAME" | tr -d '\r\n\t' | sed 's/^ *//; s/ *$//')"
  if [ "${#NAME}" -le 60 ] && printf '%s' "$NAME" | LC_ALL=C grep -qE '^[A-Za-z0-9 ._-]+$'; then ok "tag: $NAME"; break; fi
  say "   ${red}Keep it to letters, numbers, spaces . _ -  and at most 60 characters.${off}"
done

say ""
say "3) Which pool endpoint to send shares to. Press Enter for the default. If this Mac is in Asia or Europe you can use"
say "   hk.datum.xorpool.com:28915 or eu.datum.xorpool.com:28915 instead - same pool, same payout, just closer."
while :; do
  ask POOL "   DATUM pool (host:port)" "${OLD_POOL:-$POOL_HOST:$POOL_PORT}"
  POOL="$(printf '%s' "$POOL" | tr -d '[:space:]')"; POOL="${POOL#*://}"
  case "$POOL" in *:*) H="${POOL%%:*}"; P="${POOL##*:}";; *) H="$POOL"; P="$POOL_PORT";; esac
  if printf '%s' "$H" | LC_ALL=C grep -qE '^[A-Za-z0-9.-]+$' && printf '%s' "$P" | grep -qE '^[0-9]{1,5}$' && [ "$P" -ge 1 ] && [ "$P" -le 65535 ]; then
    if perl -MSocket -e 'exit(gethostbyname($ARGV[0]) ? 0 : 1)' "$H" 2>/dev/null; then POOL_HOST="$H"; POOL_PORT="$P"; ok "pool: $POOL_HOST:$POOL_PORT"; break; fi
    say "   ${red}Cannot resolve host '$H'${off} - check the spelling."; continue
  fi
  say "   ${red}Give it as host:port${off}, e.g. datum.xorpool.com:28915"
done

SNAP=0; SNAP_H=""; SNAP_HASH=""; SNAP_SHA=""; SNAP_FILE=""; SNAP_SIZE=0
if latest=$(curl -fsS --max-time 15 "$SNAPSHOT_URL" 2>/dev/null); then
  read -r SNAP_FILE SNAP_H SNAP_HASH SNAP_SHA SNAP_SIZE <<<"$(printf '%s' "$latest" | perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); print join(" ", @$d{qw(file height block_hash sha256 size_bytes)})' 2>/dev/null || true)"
fi
if [ -n "$SNAP_FILE" ]; then
  have_h=0; [ -d "$NODE_DIR/chainstate" ] && [ -x "$BIN/bitcoin-cli" ] && have_h=$("$BIN/bitcoin-cli" -datadir="$NODE_DIR" -conf="$NODE_CONF" getblockcount 2>/dev/null || echo 0)
  if [ "${have_h:-0}" -ge "$SNAP_H" ]; then
    say ""; say "Your node is already past the published snapshot (height $have_h); no snapshot needed."
  elif [ -z "$ZSTD" ]; then
    say ""; warn "a chain snapshot is available but this Mac cannot unpack .zst files. Install zstd with Homebrew (brew install zstd) and re-run to use it; otherwise the node syncs from scratch (1-3 days)."
  elif [ "$DISK_GB" -lt 35 ]; then
    say ""; warn "the chain snapshot needs ~35 GB free during install (have ${DISK_GB} GB) - skipping it; the node will sync from scratch (1-3 days)"
  else
    say ""
    say "4) Skip the initial sync? A snapshot of the pruned chain at height $SNAP_H ($((SNAP_SIZE/1073741824)) GB download) is available."
    say "   With it the node starts at the tip in minutes instead of 1-3 days. You trust this copy of history up to"
    say "   height $SNAP_H (like any bootstrap); every block after it is verified by your own node."
    if confirm_default_yes "   Download the snapshot?"; then SNAP=1; ok "snapshot: height $SNAP_H"; else say "   ok - syncing from scratch"; fi
  fi
fi

say ""
say "5) A mining box must not sleep. macOS puts a Mac to sleep after a while even when plugged in, which stops the node"
say "   and the gateway until it wakes. This sets 'sleep never' while on power (System Settings > Energy shows it; undo"
say "   any time with:  sudo pmset -c sleep 1)."
NOSLEEP=0
if confirm_default_yes "   Keep this Mac awake while plugged in?"; then NOSLEEP=1; ok "sleep: never (on power)"; else say "   ok - leaving power settings alone (make sure it stays awake some other way)"; fi

if [ -n "$OLD_PASS" ]; then RPC_PASS="$OLD_PASS"; else RPC_PASS="$(head -c 20 /dev/urandom | xxd -p | tr -d '\n')"; fi

say ""
say "${bold}Summary${off}"
say "  Payout address   $ADDR"
say "  Block tag        Bitcoin Xor / $NAME"
say "  Pool             $POOL_HOST:$POOL_PORT  (1% fee, you build the templates)"
say "  Install to       $ROOT  (node pruned, ~14 GB, RPC local-only; runs as '$SVC_USER', starts at boot)"
[ "$SNAP" -eq 1 ] && say "  Snapshot         $SNAP_FILE -> node starts at height $SNAP_H"
[ "$NOSLEEP" -eq 1 ] && say "  Power            never sleep while plugged in"
say ""
confirm "Install with these settings?" || { say "Nothing changed."; trap - EXIT; exit 0; }

# ---------------------------------------------------------------- install
say ""
say "${bold}Installing...${off}"
mkdir -p "$BIN" "$NODE_DIR" "$GW_DIR" "$LOGS"
stop_all

TMP=$(mktemp -d "${TMPDIR:-/tmp}/xordatum.XXXXXX")
cd "$TMP"
KURL="https://github.com/bitcoinknots/bitcoin/releases/download/v$KNOTS_VER"
KTAR="bitcoin-$KNOTS_VER-$KNOTS_ARCH.tar.gz"
if [ "$("$BIN/bitcoind" --version 2>/dev/null | head -1 | grep -o 'v[0-9.]*knots[0-9]*' || true)" = "v$KNOTS_VER" ]; then
  ok "Bitcoin Knots v$KNOTS_VER already installed"
else
  say "downloading Bitcoin Knots v$KNOTS_VER (~40 MB)..."
  curl -fsSLo "$KTAR" "$KURL/$KTAR" || die "download failed: $KURL/$KTAR"
  curl -fsSLo SHA256SUMS "$KURL/SHA256SUMS" || die "download failed: SHA256SUMS"
  want=$(grep " $KTAR\$" SHA256SUMS | cut -d' ' -f1); [ -n "$want" ] || die "$KTAR is not listed in SHA256SUMS"
  [ "$(sha256 "$KTAR")" = "$want" ] || die "checksum MISMATCH on $KTAR - not installing it"
  tar xzf "$KTAR"
  install -m 755 "bitcoin-$KNOTS_VER/bin/bitcoind" "bitcoin-$KNOTS_VER/bin/bitcoin-cli" "$BIN/"
  xattr -d com.apple.quarantine "$BIN/bitcoind" "$BIN/bitcoin-cli" 2>/dev/null || true
  ok "$("$BIN/bitcoind" --version | head -1)"
fi

RURL="https://github.com/iohzrd/ratum/releases/download/v$RATUM_VER"
RTAR="ratum-gateway-$RATUM_VER-$RATUM_ARCH.tar.gz"
if "$BIN/ratum-gateway" --version 2>/dev/null | grep -q " $RATUM_VER "; then
  ok "ratum-gateway $RATUM_VER already installed"
else
  say "downloading ratum-gateway $RATUM_VER (~3 MB)..."
  curl -fsSLo "$RTAR" "$RURL/$RTAR" || die "download failed: $RURL/$RTAR"
  curl -fsSLo "$RTAR.sha256" "$RURL/$RTAR.sha256" || die "download failed: $RTAR.sha256"
  [ "$(sha256 "$RTAR")" = "$(cut -d' ' -f1 "$RTAR.sha256")" ] || die "checksum MISMATCH on $RTAR - not installing it"
  tar xzf "$RTAR"
  RB=$(find . -type f -name ratum-gateway | head -1); [ -n "$RB" ] || die "ratum-gateway binary not found in the archive"
  install -m 755 "$RB" "$BIN/ratum-gateway"
  xattr -d com.apple.quarantine "$BIN/ratum-gateway" 2>/dev/null || true
  ok "$("$BIN/ratum-gateway" --version 2>&1 | head -1)"
fi
cd /; rm -rf "$TMP"

# node config - the chain data (if any) is untouched
cat > "$NODE_CONF" <<EOF
# Bitcoin Knots (BLAKE2b fork) - written by setup-datum-macos.sh on $(date -u +%Y-%m-%d)
server=1
disablewallet=1
prune=2000
txindex=0
dbcache=$([ "$MEM_MB" -ge 7000 ] && echo 2000 || echo 600)
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
chmod 600 "$NODE_CONF"
ok "node config $NODE_CONF"

# gateway config. Every value was validated to a safe character set above, so plain text is valid JSON here.
GW_API_PASS=$(json_get "$GW_CONF" api.admin_password)
[ -n "$GW_API_PASS" ] || GW_API_PASS="$(head -c 16 /dev/urandom | xxd -p | tr -d '\n')"
cat > "$GW_CONF" <<EOF
{
  "bitcoind": {"rpcurl": "http://127.0.0.1:8332", "rpcuser": "knots", "rpcpassword": "$RPC_PASS", "work_update_seconds": 40, "notify_fallback": true},
  "mining": {"pool_address": "$ADDR", "coinbase_tag_primary": "$NAME", "coinbase_tag_secondary": "$NAME"},
  "stratum": {"listen_addr": "0.0.0.0", "listen_port": $STRATUM_PORT},
  "datum": {"pool_host": "$POOL_HOST", "pool_port": $POOL_PORT, "pool_pubkey": "$POOL_PUBKEY", "pool_url": "$POOL_URL",
            "pool_pass_full_users": false, "pool_pass_workers": true, "gateway_fee_bps": 0, "pooled_mining_only": true},
  "api": {"listen_addr": "127.0.0.1", "listen_port": 8000, "admin_password": "$GW_API_PASS"}
}
EOF
chmod 640 "$GW_CONF"
ok "gateway config $GW_CONF"

# everything under the install root belongs to the service user (launchd runs the daemons as that user)
chown -R "$SVC_USER" "$ROOT"

# launchd system daemons: start at boot without a login, restart if they die, 180 s for the node to flush on stop
plist() {  # plist LABEL LOGFILE PROGRAM ARGS...
  local label="$1" log="$2"; shift 2
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n'
  printf '  <key>Label</key><string>%s</string>\n  <key>ProgramArguments</key><array>\n' "$label"
  local a; for a in "$@"; do printf '    <string>%s</string>\n' "$a"; done
  printf '  </array>\n  <key>UserName</key><string>%s</string>\n  <key>WorkingDirectory</key><string>%s</string>\n' "$SVC_USER" "$ROOT"
  printf '  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n  <key>ThrottleInterval</key><integer>5</integer>\n  <key>ExitTimeOut</key><integer>180</integer>\n'
  printf '  <key>StandardOutPath</key><string>%s</string>\n  <key>StandardErrorPath</key><string>%s</string>\n</dict></plist>\n' "$log" "$log"
}
plist "$NODE_LABEL" "$LOGS/node.log" "$BIN/bitcoind" "-datadir=$NODE_DIR" "-conf=$NODE_CONF" > "$NODE_PLIST"
plist "$GW_LABEL" "$LOGS/gateway.log" "$BIN/ratum-gateway" -c "$GW_CONF" > "$GW_PLIST"
chown root:wheel "$NODE_PLIST" "$GW_PLIST"; chmod 644 "$NODE_PLIST" "$GW_PLIST"
touch "$LOGS/node.log" "$LOGS/gateway.log"; chown "$SVC_USER" "$LOGS/node.log" "$LOGS/gateway.log"
plutil -lint "$NODE_PLIST" "$GW_PLIST" >/dev/null || die "the launchd plists did not validate"
# rotate the gateway log (the node rotates debug.log itself)
printf '# xordatum: rotate the gateway log at 10 MB, keep 5\n%s/gateway.log  %s:staff  644  5  10240  *  J\n' "$LOGS" "$SVC_USER" > /etc/newsyslog.d/xordatum.conf 2>/dev/null || true
ok "launchd services ($NODE_LABEL, $GW_LABEL)"

if [ "$NOSLEEP" -eq 1 ]; then pmset -c sleep 0 disksleep 0 >/dev/null 2>&1 && ok "power: never sleep while plugged in" || warn "could not change the power settings (set Sleep to Never in System Settings > Energy)"; fi

# a small status helper
cat > "$ROOT/datum-status" <<'EOF'
#!/bin/bash
# Shows node sync progress and gateway state in plain words.
R=/usr/local/xordatum; c="$R/bin/bitcoin-cli -datadir=$R/node -conf=$R/node/bitcoin.conf"
st() { pgrep -x "$1" >/dev/null 2>&1 && echo running || echo "NOT running"; }   # pgrep works for any user; launchctl print system/... needs root
echo "node:     $(st bitcoind)    gateway: $(st ratum-gateway)"
synced=0
if info=$($c getblockchaininfo 2>/dev/null); then
  line=$(printf '%s' "$info" | perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); my $p = $d->{verificationprogress}*100;
    printf($p > 99.99 ? "chain:    height %d  at tip\n" : "chain:    height %d  syncing %.2f%%\n", $d->{blocks}, $p)')
  echo "$line"; case "$line" in *"at tip"*) synced=1;; esac
else echo "chain:    node starting / not answering RPC yet"; fi
echo "peers:    $($c getconnectioncount 2>/dev/null || echo ?)"
if [ "$synced" -eq 0 ]; then
  echo "gateway:  waiting for the node to finish syncing (expected - your miners get work automatically once it is at the tip)"
else
  curl -s -m 3 http://127.0.0.1:8000/stats.json | perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); my $h = $d->{hashrate}{history} || [];
    my $hs = @$h ? $h->[-1][1] : 0; my $c = sub { my $x = shift; ref($x) eq "HASH" ? $x->{count} : ($x // 0) };
    printf("gateway:  %.2f TH/s   shares accepted %s   rejected %s\n", $hs/1e12, $c->($d->{shares_accepted}), $c->($d->{shares_rejected}))' 2>/dev/null || echo "gateway:  not answering yet"
  echo "last log: $(tail -1 "$R/logs/gateway.log" 2>/dev/null)"
fi
echo "logs:     $R/logs/gateway.log   node: $R/node/debug.log"
EOF
chmod 755 "$ROOT/datum-status"; ln -sf "$ROOT/datum-status" /usr/local/bin/datum-status 2>/dev/null || true

svc_start "$NODE_LABEL" "$NODE_PLIST"; sleep 3; svc_start "$GW_LABEL" "$GW_PLIST"; sleep 3
svc_running "$NODE_LABEL" || die "the node did not start - see $LOGS/node.log and $NODE_DIR/debug.log"
svc_running "$GW_LABEL" || die "the gateway did not start - see $LOGS/gateway.log"

if [ "$SNAP" -eq 1 ]; then
  say ""; say "${bold}Downloading the chain snapshot${off} ($((SNAP_SIZE/1073741824)) GB) - this is the long part, a few minutes on a good link..."
  SNAP_DIR="$ROOT/tmp"; mkdir -p "$SNAP_DIR"
  curl -fL -# --retry 5 --retry-delay 5 -C - -o "$SNAP_DIR/$SNAP_FILE" "https://snapshot.xorpool.com/$SNAP_FILE" || die "snapshot download failed - run the script again to resume it"
  say "verifying checksum..."
  [ "$(sha256 "$SNAP_DIR/$SNAP_FILE")" = "$SNAP_SHA" ] || { rm -f "$SNAP_DIR/$SNAP_FILE"; die "snapshot checksum MISMATCH - not using it. Run the script again to re-download."; }
  ok "checksum matches"
  stop_all
  rm -rf "$NODE_DIR/blocks" "$NODE_DIR/chainstate"      # only the chain data; the config and everything else stay
  if [ "$ZSTD" = "tar" ]; then tar --zstd -xf "$SNAP_DIR/$SNAP_FILE" -C "$NODE_DIR" || die "snapshot extract failed"
  else "$ZSTD" -dc "$SNAP_DIR/$SNAP_FILE" | tar -xf - -C "$NODE_DIR" || die "snapshot extract failed"; fi
  chown -R "$SVC_USER" "$NODE_DIR/blocks" "$NODE_DIR/chainstate"
  rm -f "$SNAP_DIR/$SNAP_FILE"; rmdir "$SNAP_DIR" 2>/dev/null || true
  svc_start "$NODE_LABEL" "$NODE_PLIST"; sleep 3; svc_start "$GW_LABEL" "$GW_PLIST"
  got=""; for i in $(seq 1 90); do got=$("$BIN/bitcoin-cli" -datadir="$NODE_DIR" -conf="$NODE_CONF" getblockhash "$SNAP_H" 2>/dev/null) && break; sleep 2; done
  if [ "${got:-}" = "$SNAP_HASH" ]; then ok "node started from the snapshot at height $SNAP_H; block hash verified"
  else warn "could not verify block $SNAP_H against the published hash yet (node still starting?) - check later with: datum-status"; fi
fi
trap - EXIT
IFACE=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}'); MYIP=""; [ -n "$IFACE" ] && MYIP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)

say ""
say "${grn}${bold}Done.${off}"
say ""
say "  Point your ASICs at:   ${bold}stratum+tcp://${MYIP:-<this-mac-ip>}:$STRATUM_PORT${off}"
say "                         worker:  ${bold}anything.rig1${off}   password:  ${bold}x${off}"
say ""
if [ "$SNAP" -eq 1 ]; then
  say "  The node started from the snapshot and is catching up the last few blocks - your ASICs get work within minutes."
elif [ "$UPDATE" -eq 1 ]; then
  say "  The node restarted with its existing chain data and is catching up whatever it missed - your ASICs get work within minutes."
else
  say "  The node is now syncing the chain from the start - ${bold}1 to 3 days${off}. Your ASICs get work automatically the moment"
  say "  it reaches the tip; until then the gateway waits. Leave the Mac on. (Re-run with Y to the snapshot to skip most of the wait.)"
fi
say ""
say "  If macOS asks whether 'bitcoind' or 'ratum-gateway' may accept incoming connections, click Allow - that is your ASICs"
say "  reaching the gateway on port $STRATUM_PORT (and peers reaching the node)."
say ""
say "  Check on it any time:  ${bold}datum-status${off}"
say "  Your stats once shares flow:  $POOL_URL/miner/$ADDR"
say "  Logs:  $LOGS/gateway.log   $NODE_DIR/debug.log"
say "  Stop / start:  sudo launchctl bootout system/$NODE_LABEL     sudo launchctl bootstrap system $NODE_PLIST"
say "  Remove everything:  sudo launchctl bootout system/$GW_LABEL; sudo launchctl bootout system/$NODE_LABEL;"
say "                      sudo rm -rf $ROOT $NODE_PLIST $GW_PLIST /etc/newsyslog.d/xordatum.conf /usr/local/bin/datum-status"
say ""
"$ROOT/datum-status" || true
