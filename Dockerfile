# syntax=docker/dockerfile:1
# fs-portal: expose a local media library to a remote peer over iroh, and
# FUSE-mount the peer's library locally (read-only) for sibling containers.

# dumbpipe is built from the vendored source in vendor/dumbpipe (see its
# UPSTREAM file) — no dependency on upstream's mutable release binaries.
# Dependency versions are pinned by the committed Cargo.lock (--locked).
FROM rust:1.93-alpine AS dumbpipe
RUN apk add --no-cache musl-dev
COPY vendor/dumbpipe /build
WORKDIR /build
RUN cargo build --release --locked \
 && cp target/release/dumbpipe /usr/local/bin/dumbpipe \
 && /usr/local/bin/dumbpipe --help >/dev/null

# `docker build --target dumbpipe-test .` runs upstream's own test suite
# against the vendored source; wired into test.sh, not part of the image.
FROM dumbpipe AS dumbpipe-test
RUN cargo test --release --locked 2>&1 | tee /tmp/cargo-test.log

FROM rclone/rclone:1.71
RUN apk add --no-cache bash fuse3 \
 && echo user_allow_other >> /etc/fuse.conf
COPY --from=dumbpipe /usr/local/bin/dumbpipe /usr/local/bin/dumbpipe
COPY scripts/lib.sh scripts/entrypoint.sh scripts/healthcheck.sh /opt/fs-portal/
RUN chmod +x /opt/fs-portal/entrypoint.sh /opt/fs-portal/healthcheck.sh

ENV ROLES="both" \
    EXPORT_DIR=/export \
    MOUNT_DIR=/portal/media \
    CONFIG_DIR=/config \
    FSP_CACHE_DIR=/cache

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD ["/opt/fs-portal/healthcheck.sh"]

ENTRYPOINT ["/opt/fs-portal/entrypoint.sh"]
