# ratum-gateway — the fork-native DATUM gateway (iohzrd/ratum), built from source.
FROM rust:1-bookworm AS build
# TODO: pin RATUM_REF to the exact version you run in production (currently v0.1.25 / 9dd53f9).
ARG RATUM_REF=9dd53f91d43e
RUN git clone https://github.com/iohzrd/ratum /src \
 && cd /src && git checkout "${RATUM_REF}" \
 && cargo build --release -p ratum-gateway
# ^ TODO: confirm the workspace package name is `ratum-gateway` (adjust -p if not).

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates gettext-base \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/ratum-gateway /usr/local/bin/ratum-gateway
COPY gateway.json.tmpl /gateway.json.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN mkdir -p /config && chmod +x /entrypoint.sh
EXPOSE 23334 8000 8001
ENTRYPOINT ["/entrypoint.sh"]
