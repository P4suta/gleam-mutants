# SPDX-FileCopyrightText: 2026 gleam_mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0

FROM docker.io/library/debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update \
 && apt-get install --yes --no-install-recommends ca-certificates=20250419~deb12u2 zstd=1.5.4+dfsg2-5 \
 && rm -rf /var/lib/apt/lists/*
ARG ELAN_VERSION=4.2.4
ARG ELAN_SHA256=42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63
ADD --checksum=sha256:${ELAN_SHA256} https://github.com/leanprover/elan/releases/download/v${ELAN_VERSION}/elan-x86_64-unknown-linux-gnu.tar.gz /tmp/elan.tar.gz
ARG LEAN_VERSION=4.34.1
ARG LEAN_SHA256=47bf4bbd78f70c2e9670598ab7124d92b6efb7330ff33e5fbb4030f6fd72e4e4
ADD --checksum=sha256:${LEAN_SHA256} https://github.com/leanprover/lean4/releases/download/v${LEAN_VERSION}/lean-${LEAN_VERSION}-linux.tar.zst /tmp/lean.tar.zst
ENV ELAN_HOME=/opt/elan
ENV PATH=/opt/elan/bin:$PATH
RUN echo "${ELAN_SHA256}  /tmp/elan.tar.gz" | sha256sum -c - \
 && echo "${LEAN_SHA256}  /tmp/lean.tar.zst" | sha256sum -c - \
 && tar -xzf /tmp/elan.tar.gz -C /tmp \
 && /tmp/elan-init -y --no-modify-path --default-toolchain none \
 && mkdir -p /opt/lean \
 && tar --zstd -xf /tmp/lean.tar.zst -C /opt/lean --strip-components=1 \
 && elan toolchain link leanprover/lean4:v${LEAN_VERSION} /opt/lean \
 && elan default leanprover/lean4:v${LEAN_VERSION} \
 && rm -f /tmp/elan.tar.gz /tmp/elan-init /tmp/lean.tar.zst
