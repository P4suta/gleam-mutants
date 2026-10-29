# SPDX-FileCopyrightText: 2026 gleam_mutants contributors
# SPDX-License-Identifier: MIT OR Apache-2.0

FROM docker.io/library/rust:1.99.1-slim-bookworm@sha256:24707e70a4f1e23d9a7b25202ec43126d28a52294b96aad5c670df1fd1f1d400
ENV CARGO_BUILD_JOBS=2
ENV KANI_HOME=/opt/kani
ARG KANI_VERSION=0.68.0
ARG KANI_SHA256=32e2b484d73ede0bbf64a2cf0879c4259422497d8aec4ee67d448de9ae7843d3
ADD --checksum=sha256:${KANI_SHA256} https://github.com/model-checking/kani/releases/download/kani-${KANI_VERSION}/kani-${KANI_VERSION}-x86_64-unknown-linux-gnu.tar.gz /tmp/kani.tar.gz
RUN cargo install --locked --version "${KANI_VERSION}" kani-verifier \
 && cargo kani setup --use-local-bundle /tmp/kani.tar.gz \
 && rm -f /tmp/kani.tar.gz
