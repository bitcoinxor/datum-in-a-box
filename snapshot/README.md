# Chain snapshot pipeline

A pruned-datadir snapshot lets a new box sync in minutes instead of days. Produce and publish it from
a synced, pruned fork node; point `SNAP_URL` / `SNAP_SHA` in `../setup.sh` at the latest.

## Make it (on a synced pruned node)

```sh
bitcoin-cli stop                      # clean shutdown so chainstate is consistent
H=$(bitcoin-cli getblockcount)        # (start the node again after taring, or tar an offline copy)
tar -I 'zstd -19 -T0' -cf snapshot-$H.tar.zst -C /var/lib/bitcoin blocks chainstate
sha256sum snapshot-$H.tar.zst > snapshot-$H.sha256
# restart the node
```

## Publish

- Upload `snapshot-$H.tar.zst` + `snapshot-$H.sha256` to any HTTP host (S3 / Cloudflare R2 / a VPS),
  and/or seed a torrent for bandwidth.
- Update `SNAP_URL` and `SNAP_SHA` in `setup.sh` (or keep a stable `snapshot-latest.tar.zst` alias).

## Notes

- Refresh roughly weekly — the older the snapshot, the more each box syncs forward.
- **Decentralisation is preserved:** every box still validates each block *forward* from the snapshot.
  It trusts the pruned *history* (same model as Bitcoin's pruned bootstraps), verifies the *future*.
- If the fork's Knots build supports **assumeutxo**, prefer a signed UTXO snapshot — cryptographically
  committed and cleaner than a raw datadir tar.
