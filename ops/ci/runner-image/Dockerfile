# SIS CI runner image — Rust toolchain + Node 20 (Forgejo actions need node).
#
# The stock `rust:*` images have no node, so `actions/checkout` dies with
# `exec: "node": executable file not found`. This image keeps the Rust
# toolchain (no per-job rustup install) and adds node for actions.
#
# Build on the runner host:
#   docker build -t sis-ci-rust:1 ops/ci/runner-image
#
# Then point the Forgejo runner label at it:
#   sis-rust:docker://sis-ci-rust:1
FROM rust:1-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git pkg-config libssl-dev \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# rustfmt/clippy are not in the stock image.
RUN rustup component add rustfmt clippy

# The runner mounts its cache volume here; keep cargo artefacts off the
# container layer so repeat jobs are fast.
ENV CARGO_HOME=/cache/cargo \
    CARGO_TARGET_DIR=/cache/target
