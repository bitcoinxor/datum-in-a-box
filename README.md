# DATUM-in-a-box

Run **your own** node + gateway on the Bitcoin BLAKE2b chain, so you build **your own block
templates** — real decentralization, non-custodial, and (BYO) cheaper than pooled. One VPS, two
containers, you edit **one line** (your address).

```
 your ASICs ──stratum──▶ [ratum-gateway] ──DATUM──▶ datum.xorpool.com  (payout coordination)
   (point here)               │
                              ▼
                    [pruned BLAKE2b node]  ← bootstrapped from a chain snapshot (fast)
                    builds YOUR block from YOUR mempool
```

## Recommended: a small VPS (always-on)

Any Linux VPS (~$5–10/mo, 2 vCPU / 4 GB / 40 GB disk is plenty).

```sh
git clone <this repo> && cd datum-in-a-box
cp .env.example .env
nano .env                 # change ONLY the MINER_ADDRESS line to YOUR OWN wallet address
./setup.sh                # installs, fast-syncs from the snapshot, starts everything
```

Then point your miners at **`<vps-ip>:23334`**, username = your address, password = `x`.
Status page: `http://<vps-ip>:8000`.

- **Pooled (default):** `POOL_HOST=datum.xorpool.com` → your own templates, shared TIDES payouts.
- **Solo:** blank `POOL_HOST` in `.env` → keep 100% of every block you find, no pool.

## On your own Windows PC (WSL2)

Works, but a home PC that sleeps/reboots is a worse 24/7 host than a VPS — best for testing or a
small setup. Needs Windows 11 + WSL2 + Docker.

```powershell
# in an ELEVATED PowerShell, from this folder:
./setup-windows.ps1       # sets WSL mirrored networking + firewall, then runs setup inside WSL
```
(Mirrored networking is required so your ASICs on the LAN can reach the gateway through WSL2.)

## ⚠️ Use a wallet you control

Your payout address must be **your own wallet** (make one with **Shrike**: bitcoinxor.org/wallet) —
**never an exchange deposit address.** Rewards are paid straight into your address in the block's
coinbase; exchanges don't credit that and you don't hold the keys, so the coins are lost.

## Prereqs the operator (you, Bitcoin Xor) must publish

See `DESIGN.md`. In short: build `bitcoinxor/knotsd` (the fork node image) and
`bitcoinxor/ratum-gateway`, publish a chain snapshot (`snapshot/README.md`), and set the BYO fee.

---

## 中文快速上手（草稿，请母语者校对）

在 Bitcoin BLAKE2b 链上运行**你自己的**全节点 + 网关，自己构建区块模板——真正的去中心化、非托管，
且（自建）比进矿池更便宜。你只需改**一行**（你的地址）。

**推荐：一台小型 VPS（长期在线）**
```sh
git clone <本仓库> && cd datum-in-a-box
cp .env.example .env
nano .env                 # 只改 MINER_ADDRESS 这一行，填你自己的钱包地址
./setup.sh                # 安装、用快照快速同步、启动
```
然后把矿机指向 **`<vps-ip>:23334`**，用户名 = 你的地址，密码 = `x`。状态页：`http://<vps-ip>:8000`。

- **进矿池（默认）：** `POOL_HOST=datum.xorpool.com` → 自己的模板，TIDES 共享分配。
- **单挖 Solo：** 把 `POOL_HOST` 留空 → 爆块 100% 归你，不进矿池。

**⚠️ 必须用你自己掌控的钱包地址**（用 Shrike 钱包创建），**绝不要用交易所充值地址**——奖励直接进
币基（coinbase），交易所不会入账，且私钥不在你手里，币会丢失。

**Windows（WSL2）：** 支持，但家用电脑会休眠/重启，不如 VPS 稳定，适合测试或小规模。需 Windows 11 +
WSL2 + Docker，在管理员 PowerShell 里运行 `./setup-windows.ps1`（会设置 WSL 镜像网络 + 防火墙）。
