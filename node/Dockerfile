# The Bitcoin BLAKE2b fork node (Knots v29.x based).
#
# TODO — supply the FORK daemon + cli binaries. Pick ONE:
#   (A) Build them once and drop them in ./node/ before `docker build`:
#         put `bitcoind` and `bitcoin-cli` (your BLAKE2b Knots build, linux-x86_64) in ./node/
#       Then the COPY below picks them up. (Recommended — build once, ship the image.)
#   (B) Or fetch a release you publish: replace the COPY with:
#         ARG KNOTSD_URL=https://TODO-your-release/bitcoinxor-node-linux-x86_64.tar.gz
#         RUN curl -fsSL "$KNOTSD_URL" | tar -xz -C /usr/local/bin bitcoind bitcoin-cli
#
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# --- provide the fork binaries here (see options above) ---
COPY bitcoind bitcoin-cli /usr/local/bin/
RUN chmod +x /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli

VOLUME /data
EXPOSE 8332
# flags are supplied by docker-compose `command:`
ENTRYPOINT ["bitcoind"]
