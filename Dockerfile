# syntax=docker/dockerfile:1
# fs-portal: expose a local media library to a remote peer over iroh, and
# FUSE-mount the peer's library locally (read-only) for sibling containers.

FROM alpine:3.22 AS dumbpipe
ARG DUMBPIPE_VERSION=v0.39.0
ARG TARGETARCH
RUN apk add --no-cache curl tar
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/dumbpipe.tar.gz \
      "https://github.com/n0-computer/dumbpipe/releases/download/${DUMBPIPE_VERSION}/dumbpipe-${DUMBPIPE_VERSION}-linux-${arch}.tar.gz"; \
    mkdir /tmp/out; \
    tar -xzf /tmp/dumbpipe.tar.gz -C /tmp/out; \
    find /tmp/out -type f -name dumbpipe -exec mv {} /usr/local/bin/dumbpipe \; ; \
    chmod +x /usr/local/bin/dumbpipe; \
    /usr/local/bin/dumbpipe --version || true

FROM rclone/rclone:1.71
RUN apk add --no-cache bash fuse3 \
 && echo user_allow_other >> /etc/fuse.conf
COPY --from=dumbpipe /usr/local/bin/dumbpipe /usr/local/bin/dumbpipe
COPY scripts/lib.sh scripts/entrypoint.sh scripts/healthcheck.sh /opt/fs-portal/
RUN chmod +x /opt/fs-portal/entrypoint.sh /opt/fs-portal/healthcheck.sh

ENV ROLES="export,import" \
    EXPORT_DIR=/export \
    MOUNT_DIR=/portal/media \
    CONFIG_DIR=/config \
    FSP_CACHE_DIR=/cache

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD ["/opt/fs-portal/healthcheck.sh"]

ENTRYPOINT ["/opt/fs-portal/entrypoint.sh"]
