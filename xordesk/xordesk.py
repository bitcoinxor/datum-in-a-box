#!/usr/bin/env python3
"""Xor Desk - a local dashboard for a DATUM mining box (Knots node + ratum-gateway).

Runs ON the mining machine, binds to localhost (or the LAN if you ask), sends nothing anywhere.
Shows node sync, gateway state and rigs; edits the gateway's payout address / block name / pool
endpoint; runs update, snapshot, restart; shows logs. Python 3 standard library only.

Config: /etc/xordesk.json   {"port":8090,"listen":"127.0.0.1","salt":..,"password_sha256":..,
                             "installer_tag":"v1.2.0","address":..,"name":..,"pool":"host:port"}
Node:   reads rpc login from the node's bitcoin.conf.   Gateway: /etc/ratum/gateway.json + its stats API.
"""
import json, os, re, sys, time, hmac, hashlib, secrets, subprocess, urllib.request, urllib.parse, html, base64, threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

CONF = "/etc/xordesk.json"
NODE_DIR = "/var/lib/knots"
GW_CONF = "/etc/ratum/gateway.json"
ACTION_LOG = "/var/log/xordesk/action.log"
REPO = "bitcoinxor/datum-in-a-box"
VERSION = "0.2.0"

def load_conf():
    try: return json.load(open(CONF))
    except Exception: return {}
CFG = load_conf()
SESSION_SECRET = secrets.token_bytes(32)
FAILS = {}   # ip -> [count, first_ts]

def esc(s): return html.escape(str(s if s is not None else ""))
def sh(*args, timeout=20):
    try: return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout).stdout
    except Exception as e: return ""
def unit_active(u): return sh("systemctl", "is-active", u).strip() or "unknown"

# ------------------------------------------------------------------ node
def node_rpc(method, params=None):
    conf = {}
    try:
        for line in open(os.path.join(NODE_DIR, "bitcoin.conf")):
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1); conf[k.strip()] = v.split("#")[0].strip()
    except OSError: return None
    url = "http://127.0.0.1:%s" % conf.get("rpcport", "8332")
    auth = base64.b64encode(("%s:%s" % (conf.get("rpcuser", ""), conf.get("rpcpassword", ""))).encode()).decode()
    req = urllib.request.Request(url, data=json.dumps({"jsonrpc": "1.0", "id": "xd", "method": method, "params": params or []}).encode(),
                                 headers={"Authorization": "Basic " + auth, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r: return json.load(r).get("result")
    except Exception: return None

def node_status():
    st = {"service": unit_active("knotsd"), "rpc": False}
    info = node_rpc("getblockchaininfo")
    if info:
        st.update(rpc=True, height=info.get("blocks"), headers=info.get("headers"), progress=round(info.get("verificationprogress", 0) * 100, 2),
                  ibd=info.get("initialblockdownload"), pruned=info.get("pruned"), size_gb=round(info.get("size_on_disk", 0) / 1e9, 1))
        st["at_tip"] = (not st["ibd"]) and st["progress"] >= 99.99
        st["peers"] = node_rpc("getconnectioncount")
        ni = node_rpc("getnetworkinfo") or {}; st["version"] = ni.get("subversion", "").strip("/")
    return st

# ------------------------------------------------------------------ gateway
def gw_conf():
    try: return json.load(open(GW_CONF))
    except Exception: return {}
def gw_status():
    g = gw_conf(); api = g.get("api", {}); st = {"service": unit_active("ratum-gateway"), "api": False}
    st["pool"] = "%s:%s" % (g.get("datum", {}).get("pool_host", ""), g.get("datum", {}).get("pool_port", ""))
    st["address"] = g.get("mining", {}).get("pool_address", ""); st["name"] = g.get("mining", {}).get("coinbase_tag_secondary", "")
    st["stratum_port"] = g.get("stratum", {}).get("listen_port", 23334)
    url = "http://%s:%s/stats.json" % (api.get("listen_addr", "127.0.0.1"), api.get("listen_port", 8000))
    req = urllib.request.Request(url)
    if api.get("admin_password"):
        req.add_header("Authorization", "Basic " + base64.b64encode(("admin:%s" % api["admin_password"]).encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=5) as r: d = json.load(r)
    except Exception: return st
    st["api"] = True; st["version"] = d.get("version"); st["uptime"] = d.get("uptime")
    strat = d.get("stratum") if isinstance(d.get("stratum"), dict) else {}
    st["hashrate_ths"] = round(float(strat.get("hashrate_ths") or 0), 3)
    st["connections"] = strat.get("connections")
    acc = d.get("shares_accepted") or {}; rej = d.get("shares_rejected") or {}
    st["accepted"] = acc.get("count", acc) if isinstance(acc, dict) else acc
    st["rejected"] = rej.get("count", rej) if isinstance(rej, dict) else rej
    cl = d.get("clients") or []
    if isinstance(cl, dict): cl = list(cl.values())
    st["rigs"] = []
    for c in cl:
        st["rigs"].append({"worker": c.get("username") or "?", "host": str(c.get("remote") or "").rsplit(":", 1)[0],
                           "hashrate_ths": round(float(c.get("hashrate_ths") or 0), 3), "accepted": c.get("accepted_count", ""), "rejected": c.get("rejected_count", ""),
                           "agent": c.get("useragent", ""), "vardiff": c.get("vardiff", ""), "last_share_s": int(c.get("last_accepted_seconds") or 0),
                           "connected_min": int((c.get("subscribed_seconds") or 0) // 60), "unpayable": bool(c.get("unpayable"))})
    st["stratum"] = strat
    return st

def fetch_json(url, timeout=8):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "xordesk/" + VERSION, "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r: return json.load(r)
    except Exception: return None

def snapshot_info(): return fetch_json("https://snapshot.xorpool.com/latest.json")

def vtuple(t):
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)$", t or ""); return tuple(int(x) for x in m.groups()) if m else (0, 0, 0)
def latest_release():
    """Newest vX.Y.Z tag of the repo (tags, not GitHub Releases)."""
    tags = fetch_json("https://api.github.com/repos/%s/tags?per_page=30" % REPO) or []
    names = [t.get("name", "") for t in tags if isinstance(t, dict)]
    names = [n for n in names if vtuple(n) != (0, 0, 0)]
    return max(names, key=vtuple) if names else None

def pool_earnings(pool_host, address):
    """Pull (never push) this address's public stats from the pool it is pointed at, if the pool has an API we know."""
    if not address or not pool_host: return None
    if pool_host.endswith("xorpool.com"):
        d = fetch_json("https://xorpool.com/api/datum/miner/%s" % urllib.parse.quote(address)) or {}
        d["_page"] = "https://xorpool.com/datum/miner/" + address; return d
    return None

# ------------------------------------------------------------------ actions (run detached; one at a time)
def action_running(): return unit_active("xordesk-action") in ("active", "activating")
def action_log(n=60):
    try: return "".join(open(ACTION_LOG, errors="replace").readlines()[-n:])
    except OSError: return ""
def run_action(name, script):
    if action_running(): return False
    os.makedirs(os.path.dirname(ACTION_LOG), exist_ok=True)
    with open(ACTION_LOG, "w") as f: f.write("== %s  %s\n" % (name, time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())))
    sh("systemctl", "reset-failed", "xordesk-action")
    subprocess.run(["systemd-run", "--unit", "xordesk-action", "--collect", "-p", "StandardOutput=append:" + ACTION_LOG, "-p", "StandardError=append:" + ACTION_LOG,
                    "bash", "-c", script], capture_output=True, text=True)
    return True
def installer_script(tag):
    return ("set -e; curl -fsSLo /var/tmp/setup-datum.sh https://raw.githubusercontent.com/%s/%s/setup-datum.sh && " % (REPO, tag))
def answers_file(snapshot):
    c = load_conf()
    a = "%s\n%s\n%s\n" % (c.get("address", ""), c.get("name", ""), c.get("pool", ""))
    a += ("y\n" if snapshot else "n\n") + "y\n"   # snapshot question (only asked when one is offered), then the confirm
    p = "/var/tmp/xordesk-answers.txt"; open(p, "w").write(a); os.chmod(p, 0o600); return p

# ------------------------------------------------------------------ auth
def check_password(pw):
    c = load_conf(); h = hashlib.sha256((c.get("salt", "") + pw).encode()).hexdigest()
    return hmac.compare_digest(h, c.get("password_sha256", "x"))
def make_token(): return hmac.new(SESSION_SECRET, b"session", hashlib.sha256).hexdigest()
def csrf(): return make_token()[:24]

# ------------------------------------------------------------------ html
CSS = """
:root{--paper:#F4F6F5;--card:#fff;--grid:#E3E8E7;--ink:#1A232D;--muted:#4A5763;--accent:#2E8FA3;--ok:#1E8A48;--bad:#C0392B;--warn:#B7791F}
@media (prefers-color-scheme:dark){:root{--paper:#0F141A;--card:#1A222C;--grid:#2C3846;--ink:#F2F5F8;--muted:#AAB6C2;--accent:#7FB0EC;--ok:#5FCB7A;--bad:#FF7B72;--warn:#E0B95A}}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.5 Inter,system-ui,sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:0 20px}.wrap.wide{max-width:none}
.top{border-bottom:1px solid var(--grid);position:sticky;top:0;background:var(--paper);z-index:2}
.top .wrap{display:flex;align-items:center;gap:22px;height:58px;max-width:none}.brand{font-weight:700;font-size:18px;white-space:nowrap}.brand span{color:var(--muted);font-weight:500;font-size:13px;margin-left:8px}
nav a{color:var(--muted);text-decoration:none;font-weight:500;margin-right:16px}nav a[aria-current]{color:var(--ink)}.spacer{flex:1}
.live{font-size:12px;color:var(--muted)}.live i{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--ok);margin-right:6px;vertical-align:middle}.live.off i{background:var(--bad)}
main{padding:26px 0 60px}h1{font-size:24px;margin:0 0 14px}h2{font-size:17px;margin:0 0 10px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px}
.card{background:var(--card);border:1px solid var(--grid);border-radius:12px;padding:16px 18px;min-width:0}.card+.card{margin-top:14px}.grid .card+.card{margin-top:0}
.kv{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:6px 14px;font-variant-numeric:tabular-nums;align-items:baseline}.kv b{color:var(--muted);font-weight:500;white-space:nowrap}.kv span{min-width:0;overflow-wrap:anywhere}
.pill{display:inline-block;padding:1px 9px;border-radius:12px;font-size:12px;font-weight:700;white-space:nowrap}.pill.ok{background:color-mix(in srgb,var(--ok) 18%,transparent);color:var(--ok)}
.pill.bad{background:color-mix(in srgb,var(--bad) 18%,transparent);color:var(--bad)}.pill.warn{background:color-mix(in srgb,var(--warn) 22%,transparent);color:var(--warn)}.pill.muted{background:var(--grid);color:var(--muted)}
.big{font-size:26px;font-weight:600;line-height:1.1}.muted{color:var(--muted)}.small{font-size:13.5px}.mono{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:14px}
table{border-collapse:collapse;width:100%;margin-top:6px}th,td{padding:8px 10px;border-bottom:1px solid var(--grid);text-align:left;font-variant-numeric:tabular-nums}th{color:var(--muted);font-size:13px;font-weight:600}.num{text-align:right}
.f{display:grid;gap:14px}.f label{display:block;font-size:13.5px;color:var(--muted);margin-bottom:5px}
input[type=text],input[type=password]{width:100%;background:var(--paper);border:1px solid var(--grid);color:var(--ink);padding:10px 12px;border-radius:8px;font:inherit}input.mono{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:14px}
button,.btn{background:var(--accent);color:#fff;border:0;padding:9px 16px;border-radius:8px;font:inherit;font-weight:600;cursor:pointer;text-decoration:none;display:inline-block}
button.sec,.btn.sec{background:var(--card);color:var(--ink);border:1px solid var(--grid)}button[disabled]{opacity:.45;cursor:default}
.tabs{display:flex;gap:6px;margin-bottom:12px}.tabs a{padding:7px 14px;border-radius:8px;border:1px solid var(--grid);color:var(--muted);text-decoration:none;font-weight:600}.tabs a[aria-current]{background:var(--accent);color:#fff;border-color:var(--accent)}
pre{background:var(--card);border:1px solid var(--grid);border-radius:10px;padding:12px 14px;overflow:auto;font-size:13px;line-height:1.45;margin:0}pre.log{max-height:calc(100vh - 200px)}
.banner{border-radius:12px;padding:14px 18px;font-weight:600;margin-bottom:16px}.banner.ok{background:color-mix(in srgb,var(--ok) 14%,transparent);color:var(--ok)}
.banner.warn{background:color-mix(in srgb,var(--warn) 18%,transparent);color:var(--warn)}.banner.bad{background:color-mix(in srgb,var(--bad) 14%,transparent);color:var(--bad)}
.row{display:flex;flex-wrap:wrap;gap:10px;align-items:center}.note{color:var(--muted);font-size:14px;margin:0}
.bar{height:10px;border-radius:6px;background:var(--grid);overflow:hidden;margin:6px 0 2px}.bar i{display:block;height:100%;background:var(--accent);width:0;transition:width .6s}
.card p{margin:0 0 12px}.card p:last-child{margin-bottom:0}
"""
JS = r"""
(function(){
var dot=document.getElementById('livedot');
function setText(id,v){var e=document.getElementById(id);if(e&&e.textContent!==String(v))e.textContent=v}
function setPill(id,cls,text){var e=document.getElementById(id);if(!e)return;var c='pill '+cls;if(e.className!==c)e.className=c;if(e.textContent!==text)e.textContent=text}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
function tick(){fetch('/api/status',{cache:'no-store'}).then(function(r){if(r.status===401||r.redirected){location.href='/login';return null}return r.json()}).then(function(d){
 if(!d)return; if(dot)dot.className='live';
 var n=d.node,g=d.gateway;
 if(n){setPill('n-service',n.service==='active'?'ok':'bad',n.service);
   if(n.rpc){setPill('n-chain',n.at_tip?'ok':'warn',n.at_tip?'at tip':'syncing '+n.progress+'%');setText('n-height',n.height+' / '+n.headers+' headers');setText('n-peers',n.peers);setText('n-version',n.version||'-');setText('n-disk',n.size_gb+' GB (pruned)');
     var bar=document.getElementById('syncbar');if(bar){document.getElementById('syncwrap').hidden=!!n.at_tip;bar.style.width=n.progress+'%';setText('syncpct',n.progress+'%')}}
   else setPill('n-chain','warn','RPC not answering')}
 if(g){setPill('g-service',g.service==='active'?'ok':'bad',g.service);setText('g-hash',(g.api?g.hashrate_ths:'-')+' TH/s');setText('g-rigs',g.api?g.rigs.length:'-');setText('g-shares',(g.accepted!=null?g.accepted:'-')+' accepted, '+(g.rejected!=null?g.rejected:'-')+' rejected');setText('g-version',g.version||'-');
   var tb=document.getElementById('rigs');if(tb){var h='';g.rigs.forEach(function(r){h+='<tr><td class=mono>'+esc(r.worker)+(r.unpayable?' <span class="pill bad">unpayable</span>':'')+'</td><td class=mono>'+esc(r.host)+'</td><td class=num>'+r.hashrate_ths+'</td><td class=num>'+r.accepted+'</td><td class=num>'+r.rejected+'</td><td class=num>'+r.vardiff+'</td><td class=num>'+r.last_share_s+'s ago</td><td class=num>'+r.connected_min+' min</td><td class=small>'+esc(r.agent)+'</td></tr>'});if(tb.innerHTML!==h)tb.innerHTML=h;var e=document.getElementById('norigs');if(e)e.hidden=g.rigs.length>0}}
 var b=document.getElementById('banner');if(b&&d.banner){var c='banner '+d.banner[0];if(b.className!==c)b.className=c;if(b.textContent!==d.banner[1])b.textContent=d.banner[1]}
 var al=document.getElementById('actlog');if(al&&d.action_log!=null&&al.textContent!==d.action_log){al.textContent=d.action_log;al.scrollTop=al.scrollHeight}
 var ar=document.getElementById('actrun');if(ar){ar.hidden=!d.action_running;document.querySelectorAll('button[data-act]').forEach(function(x){if(!x.dataset.locked)x.disabled=!!d.action_running})}
}).catch(function(){if(dot)dot.className='live off'})}
setInterval(tick,15000);
var lg=document.getElementById('logpre');if(lg){setInterval(function(){fetch('/api/log?u='+lg.dataset.u,{cache:'no-store'}).then(function(r){return r.text()}).then(function(t){if(lg.textContent!==t){var atEnd=lg.scrollTop+lg.clientHeight>=lg.scrollHeight-4;lg.textContent=t;if(atEnd)lg.scrollTop=lg.scrollHeight}}).catch(function(){})},10000)}
})();
"""
def page(title, body, current="/", wide=False):
    nav = "".join('<a href="%s"%s>%s</a>' % (h, ' aria-current="page"' if current == h else "", n) for h, n in (("/", "Overview"), ("/rigs", "Rigs"), ("/settings", "Settings"), ("/actions", "Actions"), ("/logs", "Logs")))
    return ("<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>%s - Xor Desk</title><style>%s</style></head><body>"
            "<div class=top><div class=wrap><div class=brand>Xor Desk<span>your node, your gateway</span></div><nav>%s</nav><span class=spacer></span><span class=live id=livedot title='updates in place every 15 s'><i></i>live</span><a class='muted small' href='/logout' style='margin-left:16px'>log out</a></div></div>"
            "<main><div class='wrap%s'>%s</div></main><script>%s</script></body></html>") % (esc(title), CSS, nav, " wide" if wide else "", body, JS)

def pill(ok, text, warn=False, id=""): return '<span class="pill %s"%s>%s</span>' % ("ok" if ok else ("warn" if warn else "bad"), (' id="%s"' % id) if id else "", esc(text))

def banner_for(n, g):
    if n.get("at_tip") and g["service"] == "active" and g.get("api"):
        k = len(g.get("rigs", [])); return ("ok", "Mining your own blocks: node at the tip, gateway up, %d rig%s connected." % (k, "" if k == 1 else "s"))
    if n.get("rpc") and not n.get("at_tip"): return ("warn", "Node still syncing (%s%%) - the gateway serves no work until it reaches the tip. Wait, or take the chain snapshot under Actions to skip most of it." % n.get("progress"))
    if n["service"] != "active": return ("bad", "The node service is not running. Check Logs, or restart it under Actions.")
    if g["service"] != "active": return ("bad", "The gateway service is not running. Check Logs, or restart it under Actions.")
    return ("warn", "Waiting for the node to answer.")

def overview():
    n, g = node_status(), gw_status(); c = load_conf(); bk, bt = banner_for(n, g)
    syncing = bool(n.get("rpc") and not n.get("at_tip"))
    sync = ('<div id=syncwrap%s style="margin-top:10px"><div class=bar><i id=syncbar style="width:%s%%"></i></div><span class="small muted"><span id=syncpct>%s%%</span> of the chain verified</span></div>'
            % ("" if syncing else " hidden", n.get("progress", 0), n.get("progress", 0)))
    node = ('<div class=card><h2>Node</h2><div class=kv>'
            '<b>service</b><span>%s</span><b>chain</b><span>%s</span><b>height</b><span id=n-height>%s / %s headers</span><b>peers</b><span id=n-peers>%s</span><b>version</b><span class=small id=n-version>%s</span><b>disk</b><span id=n-disk>%s GB (pruned)</span></div>%s</div>'
            % (pill(n["service"] == "active", n["service"], id="n-service"),
               (pill(True, "at tip", id="n-chain") if n.get("at_tip") else pill(False, "syncing %s%%" % n.get("progress", "?"), warn=True, id="n-chain")) if n.get("rpc") else pill(False, "RPC not answering", warn=True, id="n-chain"),
               n.get("height", "-"), n.get("headers", "-"), n.get("peers", "-"), n.get("version", "-"), n.get("size_gb", "-"), sync))
    gw = ('<div class=card><h2>Gateway</h2><div class=kv>'
          '<b>service</b><span>%s</span><b>hashrate</b><span class=big id=g-hash>%s TH/s</span><b>rigs</b><span id=g-rigs>%s</span><b>shares</b><span id=g-shares>%s accepted, %s rejected</span><b>pool</b><span class=mono>%s</span><b>version</b><span class=small id=g-version>%s</span></div></div>'
          % (pill(g["service"] == "active", g["service"], id="g-service"), g.get("hashrate_ths", "-") if g.get("api") else "-", len(g.get("rigs", [])) if g.get("api") else "-",
             g.get("accepted", "-"), g.get("rejected", "-"), esc(g["pool"]), g.get("version", "-")))
    earn = pool_earnings(g["pool"].split(":")[0], g["address"])
    if earn and earn.get("in_window"):
        rows = ("<b>in the payout window</b><span>%s</span><b>share of next block</b><span>%s%%</span><b>hashrate seen by pool</b><span>%s TH/s</span><b>pays if a block is found now</b><span>%s</span><b>blocks paid so far</b><span>%s</span><b>total paid</b><span>%s</span><b>pool fee</b><span>%s%%</span>"
                % (pill(earn.get("payable") is not False, "yes" if earn.get("payable") is not False else "unpayable address"), earn.get("share_percent", 0), earn.get("hashrate_ths", 0), earn.get("pays_if_block_now", 0), earn.get("blocks_paid", 0), earn.get("total_paid", 0), earn.get("fee_pct", "")))
    elif earn and "in_window" in earn:
        rows = "<b>in the payout window</b><span class=muted>not yet - appears after your first share</span><b>blocks paid so far</b><span>%s</span><b>total paid</b><span>%s</span>" % (earn.get("blocks_paid", 0), earn.get("total_paid", 0))
    elif earn: rows = "<span class=muted>pool stats not reachable right now</span>"
    else: rows = None
    if rows is not None:
        e = '<div class=card><h2>On the pool</h2><div class="kv small">%s</div><p class=note style="margin-top:12px"><a href="%s">Your page on the pool &rarr;</a> <span class=muted>(pulled when you open this page; nothing is sent)</span></p></div>' % (rows, esc(earn["_page"]))
    else:
        e = '<div class=card><h2>On the pool</h2><p class=note>This gateway points at <span class=mono>%s</span>. Earnings are shown on that pool\'s own site.</p></div>' % esc(g["pool"])
    ident = ('<div class=card><h2>This box</h2><div class="kv small"><b>payout address</b><span class=mono>%s</span><b>block name</b><span>%s</span><b>miners connect to</b><span class=mono>stratum+tcp://&lt;this machine&gt;:%s</span><b>installer</b><span>%s &middot; Xor Desk %s</span></div></div>'
             % (esc(g["address"]), esc(g["name"]), g["stratum_port"], esc(c.get("installer_tag", "?")), VERSION))
    body = "<h1>Overview</h1><div class='banner %s' id=banner>%s</div><div class=grid>%s%s%s%s</div><p class='note' style='margin-top:14px'>Values update in place every 15 s. Nothing on this page leaves this machine except the pull of your public pool stats.</p>" % (bk, esc(bt), node, gw, e, ident)
    return page("Overview", body, "/")

def rigs():
    g = gw_status()
    if not g.get("api"): inner = "<p class=note>The gateway API is not answering (is the gateway running, and is <span class=mono>api.admin_password</span> set in gateway.json?).</p>"
    else:
        rows = "".join("<tr><td class=mono>%s%s</td><td class=mono>%s</td><td class=num>%s</td><td class=num>%s</td><td class=num>%s</td><td class=num>%s</td><td class=num>%ss ago</td><td class=num>%s min</td><td class=small>%s</td></tr>"
                       % (esc(r["worker"]), ' <span class="pill bad">unpayable</span>' if r["unpayable"] else "", esc(r["host"]), r["hashrate_ths"], esc(r["accepted"]), esc(r["rejected"]), esc(r["vardiff"]), r["last_share_s"], r["connected_min"], esc(r["agent"])) for r in g["rigs"])
        inner = ("<p class=note id=norigs%s>No rigs connected. Point one at <span class=mono>stratum+tcp://&lt;this machine&gt;:%s</span>, worker <span class=mono>anything.rig1</span>, password <span class=mono>x</span>.</p>"
                 "<table><thead><tr><th>Worker</th><th>From</th><th class=num>TH/s</th><th class=num>Accepted</th><th class=num>Rejected</th><th class=num>Diff</th><th class=num>Last share</th><th class=num>Connected</th><th>Agent</th></tr></thead><tbody id=rigs>%s</tbody></table>"
                 % (" hidden" if g["rigs"] else "", g["stratum_port"], rows))
    return page("Rigs", "<h1>Rigs</h1><div class=card>%s</div><p class=note style='margin-top:12px'>Per-connection counts since each rig connected. A reject rate under 2%% is normal; higher usually means the rig is slow to switch to new work.</p>" % inner, "/rigs")

def settings(msg=""):
    g = gw_conf(); m = g.get("mining", {}); d = g.get("datum", {})
    body = ('<h1>Settings</h1>%s<div class=card><form class=f method=post action="/settings"><input type=hidden name=csrf value="%s">'
            '<div><label>Payout address &mdash; a wallet you hold the keys to, never an exchange deposit address</label><input type=text name=address value="%s" class=mono spellcheck=false></div>'
            '<div><label>Block name &mdash; up to 60 characters, stamped into every block you help find</label><input type=text name=name value="%s"></div>'
            '<div><label>DATUM pool endpoint (host:port)</label><input type=text name=pool value="%s:%s" class=mono spellcheck=false></div>'
            '<div><label>Pool public key &mdash; only changes if you move to another pool</label><input type=text name=pubkey value="%s" class=mono spellcheck=false></div>'
            '<div class=row><button>Save and restart the gateway</button><span class=note>Takes effect within seconds; rigs reconnect on their own.</span></div></form></div>'
            % (msg, csrf(), esc(m.get("pool_address", "")), esc(m.get("coinbase_tag_secondary", "")), esc(d.get("pool_host", "")), esc(d.get("pool_port", "")), esc(d.get("pool_pubkey", ""))))
    return page("Settings", body, "/settings")
def save_settings(form):
    addr = (form.get("address") or "").strip(); name = (form.get("name") or "").strip(); pool = (form.get("pool") or "").strip(); pk = (form.get("pubkey") or "").strip().lower()
    if not valid_address(addr): return settings('<div class="banner bad">That is not a valid address on this chain (check every character).</div>')
    if not (0 < len(name) <= 60 and re.match(r"^[A-Za-z0-9 ._-]+$", name)): return settings('<div class="banner bad">Block name: letters, numbers, spaces . _ - only, up to 60 characters.</div>')
    if ":" not in pool: return settings('<div class="banner bad">Pool endpoint must be host:port.</div>')
    host, port = pool.rsplit(":", 1)
    if not (re.match(r"^[A-Za-z0-9.-]+$", host) and port.isdigit() and 0 < int(port) < 65536): return settings('<div class="banner bad">Pool endpoint must be host:port.</div>')
    if not re.match(r"^[0-9a-f]{128}$", pk): return settings('<div class="banner bad">Pool public key must be 128 hex characters.</div>')
    g = gw_conf(); g.setdefault("mining", {}); g.setdefault("datum", {})
    g["mining"]["pool_address"] = addr; g["mining"]["coinbase_tag_primary"] = name; g["mining"]["coinbase_tag_secondary"] = name
    g["datum"]["pool_host"] = host; g["datum"]["pool_port"] = int(port); g["datum"]["pool_pubkey"] = pk
    tmp = GW_CONF + ".tmp"; json.dump(g, open(tmp, "w"), indent=2); os.replace(tmp, GW_CONF)
    c = load_conf(); c.update(address=addr, name=name, pool="%s:%s" % (host, port)); json.dump(c, open(CONF, "w"), indent=2)
    sh("systemctl", "restart", "ratum-gateway")
    return settings('<div class="banner ok">Saved. Gateway restarted.</div>')

def actions(msg=""):
    n = node_status(); c = load_conf(); snap = snapshot_info(); latest = latest_release(); running = action_running()
    cur = c.get("installer_tag", "")
    if latest and vtuple(latest) > vtuple(cur): upd_pill = '<span class="pill warn">newer release available: %s</span>' % esc(latest); upd_ok = True
    elif latest: upd_pill = '<span class="pill ok">installed %s is the newest release</span>' % esc(cur); upd_ok = True
    else: upd_pill = '<span class="pill muted">could not reach GitHub to check</span>'; upd_ok = False
    behind = bool(snap and n.get("height") is not None and n["height"] < snap.get("height", 0))
    if snap and behind: snap_txt = "<p>The pool publishes a copy of a fully verified pruned node's chain data (height %s, %.1f GB). This downloads it <b>to this machine</b>, checks its sha256 against the published one, replaces this node's chain data with it and verifies the block hash - so the node is at the tip in minutes instead of syncing for days. Settings, wallet and gateway are untouched.</p>" % (snap["height"], snap.get("size_bytes", 0) / 1e9)
    elif snap: snap_txt = "<p>The pool's published snapshot is at height %s and this node is at %s - already past it, so there is nothing to fetch. This matters only for a node that is still syncing.</p>" % (snap["height"], n.get("height", "?"))
    else: snap_txt = "<p class=note>Could not reach the snapshot index right now.</p>"
    dis = " disabled" if running else ""
    body = ('<h1>Actions</h1>%s<div class=card><h2>Update</h2><p>Fetches the newest installer from GitHub and re-runs it with your saved answers: current Knots and ratum releases, checksums verified; chain data, settings and password are kept.</p>'
            '<div class=row><form method=post action="/act"><input type=hidden name=csrf value="%s"><input type=hidden name=what value=update><button data-act=1%s>Update now</button></form>%s<span class=small>installed: <span class=mono>%s</span></span></div></div>'
            '<div class=card><h2>Chain snapshot</h2>%s<form method=post action="/act" style="margin-top:12px"><input type=hidden name=csrf value="%s"><input type=hidden name=what value=snapshot><button data-act=1%s>Download the snapshot to this machine</button></form></div>'
            '<div class=card><h2>Restart</h2><div class=row><form method=post action="/act"><input type=hidden name=csrf value="%s"><input type=hidden name=what value=restart-node><button class=sec data-act=1%s>Restart node</button></form>'
            '<form method=post action="/act"><input type=hidden name=csrf value="%s"><input type=hidden name=what value=restart-gateway><button class=sec data-act=1%s>Restart gateway</button></form></div></div>'
            '<div class=card><div class=row style="margin-bottom:8px"><h2 style="margin:0">Action log</h2><span class="pill warn" id=actrun%s>running</span></div><pre id=actlog style="max-height:40vh">%s</pre></div>'
            % (msg, csrf(), (dis if upd_ok else " disabled data-locked=1"), upd_pill, esc(cur or "?"), snap_txt, csrf(), (dis if behind else " disabled data-locked=1"), csrf(), dis, csrf(), dis, "" if running else " hidden", esc(action_log()) or "(nothing yet)"))
    return page("Actions", body, "/actions")
def do_action(form):
    what = form.get("what")
    if action_running(): return actions('<div class="banner warn">An action is already running.</div>')
    tag = latest_release() or load_conf().get("installer_tag") or "main"
    if what == "update":
        run_action("update to %s" % tag, installer_script(tag) + "bash /var/tmp/setup-datum.sh < %s" % answers_file(False))
        c = load_conf(); c["installer_tag"] = tag; json.dump(c, open(CONF, "w"), indent=2)
    elif what == "snapshot":
        run_action("snapshot", installer_script(tag) + "bash /var/tmp/setup-datum.sh < %s" % answers_file(True))
    elif what == "restart-node": sh("systemctl", "restart", "knotsd"); return actions('<div class="banner ok">Node restarting.</div>')
    elif what == "restart-gateway": sh("systemctl", "restart", "ratum-gateway"); return actions('<div class="banner ok">Gateway restarting.</div>')
    else: return actions('<div class="banner bad">Unknown action.</div>')
    return actions('<div class="banner ok">Started - the log below updates as it runs.</div>')

UNITS = {"gateway": "ratum-gateway", "node": "knotsd", "desk": "xordesk", "action": "xordesk-action"}
def log_text(which):
    return sh("journalctl", "-u", UNITS.get(which, "ratum-gateway"), "-n", "300", "--no-pager", "-o", "short", timeout=15) or "(empty)"
def logs(which="gateway"):
    which = which if which in UNITS else "gateway"
    tabs = "".join('<a href="/logs?u=%s"%s>%s</a>' % (k, ' aria-current="page"' if which == k else "", k) for k in UNITS)
    return page("Logs", "<h1>Logs</h1><div class=tabs>%s</div><pre class=log id=logpre data-u=%s>%s</pre><p class=note style='margin-top:10px'>Last 300 lines; updates in place every 10 s.</p>" % (tabs, which, esc(log_text(which))), "/logs", wide=True)

LOGIN = """<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Xor Desk</title><style>%s
.box{max-width:400px;margin:12vh auto 0}</style></head><body><main><div class="wrap box"><div class=card><h1 style="margin:0 0 4px">Xor Desk</h1><p class=note style="margin:0 0 14px">Local dashboard for this mining machine.</p>%s
<form class=f method=post action="/login"><div><label>Password (set by the installer)</label><input type=password name=pw autofocus></div><div><button>Log in</button></div></form></div></div></main></body></html>"""

# ------------------------------------------------------------------ http
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, body, code=200, headers=()):
        b = body.encode(); self.send_response(code); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(b))); self.send_header("Cache-Control", "no-store")
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)
    def redirect(self, to, headers=()):
        self.send_response(303); self.send_header("Location", to)
        for k, v in headers: self.send_header(k, v)
        self.end_headers()
    def authed(self):
        ck = self.headers.get("Cookie") or ""
        m = re.search(r"xordesk=([0-9a-f]{64})", ck)
        return bool(m and hmac.compare_digest(m.group(1), make_token()))
    def form(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n).decode() if n else ""
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); p = u.path; qs = urllib.parse.parse_qs(u.query)
        if p == "/login": return self.send(LOGIN % (CSS, ""))
        if p == "/logout": return self.redirect("/login", [("Set-Cookie", "xordesk=; Path=/; Max-Age=0")])
        if not self.authed(): return self.redirect("/login")
        try:
            if p == "/": return self.send(overview())
            if p == "/rigs": return self.send(rigs())
            if p == "/settings": return self.send(settings())
            if p == "/actions": return self.send(actions())
            if p == "/logs": return self.send(logs((qs.get("u") or ["gateway"])[0]))
            if p == "/api/status":
                n, g = node_status(), gw_status()
                d = {"node": n, "gateway": g, "banner": banner_for(n, g), "action_running": action_running(), "action_log": action_log() or "(nothing yet)"}
                b = json.dumps(d).encode(); self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.send_header("Cache-Control", "no-store"); self.end_headers(); return self.wfile.write(b)
            if p == "/api/log":
                b = log_text((qs.get("u") or ["gateway"])[0]).encode(); self.send_response(200); self.send_header("Content-Type", "text/plain; charset=utf-8"); self.send_header("Content-Length", str(len(b))); self.send_header("Cache-Control", "no-store"); self.end_headers(); return self.wfile.write(b)
            return self.send(page("Not found", "<h1>Not found</h1>"), 404)
        except Exception as e:
            return self.send(page("Error", "<h1>Something broke</h1><pre>%s</pre>" % esc(e)), 500)
    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path; f = self.form(); ip = self.client_address[0]
        if p == "/login":
            cnt, t0 = FAILS.get(ip, [0, time.time()])
            if time.time() - t0 > 600: cnt, t0 = 0, time.time()
            if cnt >= 20: return self.send(LOGIN % (CSS, '<div class="banner bad">Too many attempts. Try again in 10 minutes.</div>'), 429)
            if check_password(f.get("pw", "")):
                FAILS.pop(ip, None); return self.redirect("/", [("Set-Cookie", "xordesk=%s; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000" % make_token())])
            FAILS[ip] = [cnt + 1, t0]; time.sleep(1); return self.send(LOGIN % (CSS, '<div class="banner bad">Wrong password.</div>'), 401)
        if not self.authed(): return self.redirect("/login")
        if not hmac.compare_digest(f.get("csrf", ""), csrf()): return self.send(page("Error", "<h1>Bad request</h1><p>Form token mismatch; go back and try again.</p>"), 400)
        try:
            if p == "/settings": return self.send(save_settings(f))
            if p == "/act": return self.send(do_action(f))
            return self.send(page("Not found", "<h1>Not found</h1>"), 404)
        except Exception as e:
            return self.send(page("Error", "<h1>Something broke</h1><pre>%s</pre>" % esc(e)), 500)

if __name__ == "__main__":
    if not CFG.get("password_sha256"): print("no password in %s - run the installer" % CONF, file=sys.stderr); sys.exit(1)
    host, port = CFG.get("listen", "127.0.0.1"), int(CFG.get("port", 8090))
    print("Xor Desk %s on http://%s:%s" % (VERSION, host, port))
    ThreadingHTTPServer((host, port), H).serve_forever()
