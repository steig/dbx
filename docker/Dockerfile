# Official `dbx serve` image — the persistent wizard for team / headless use.
#
# Database engines are deliberately NOT bundled: pg_dump / mysqldump / psql run
# INSIDE the managed postgres-dbx / mysql-dbx containers via `docker exec`, which
# this container drives through the host Docker daemon (mounted socket). The
# image therefore carries the dbx CLI + wizard server + the host-side tools dbx
# shells out to (compression, encryption, ssh, the docker client), nothing more.
#
# See docs/container.md for the run/compose recipe. Local single-user setups
# should keep running `dbx wizard` as a host process — this image is for the
# always-on team server.
FROM alpine:3.20

# Host-side runtime deps. `docker-cli` is the client only (no daemon) — it talks
# to the host daemon via the bind-mounted /var/run/docker.sock. `gzip` provides
# gunzip (legacy backups); `age`/`gnupg` do backup encryption; `openssh-client`
# powers SSH tunnels to remote sources; `python3` runs the wizard server (stdlib
# only, no pip deps).
RUN apk add --no-cache \
        bash \
        python3 \
        docker-cli \
        jq \
        zstd \
        curl \
        openssh-client \
        age \
        gnupg \
        gzip \
        pv \
        ca-certificates

# MinIO client for `dbx storage` S3 offload. Alpine's `mc` package is Midnight
# Commander, not MinIO — so fetch the static MinIO binary for the build's target
# architecture (buildx sets TARGETARCH to amd64 / arm64, which match min.io's
# release path names).
#
# Pinned to an archived release and checked against the digest min.io publishes
# beside it (…/archive/<release>.sha256sum). The unpinned `/mc` path is a moving
# target: it turned an unrelated PR red when dl.min.io reset the connection, and
# it silently changes what lands in a published image. Bump deliberately — the
# digests below come from the .sha256sum files for the same release.
#
# TARGETARCH is declared bare on purpose. `ARG TARGETARCH=amd64` does NOT mean
# "amd64 unless building for something else" — the default shadows the value
# BuildKit injects, so every arch resolved to amd64 and the published arm64
# image carried an amd64 mc that could not execute. Without a default, a build
# that doesn't supply it (legacy non-BuildKit builder) falls into the case
# below and fails loudly instead.
ARG TARGETARCH
ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z
ARG MC_SHA256_amd64=01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891
ARG MC_SHA256_arm64=14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) mc_sha="$MC_SHA256_amd64" ;; \
      arm64) mc_sha="$MC_SHA256_arm64" ;; \
      *) echo "no pinned mc checksum for TARGETARCH='$TARGETARCH'" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused \
        "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/archive/mc.${MC_RELEASE}" \
        -o /usr/local/bin/mc; \
    echo "${mc_sha}  /usr/local/bin/mc" | sha256sum -c -; \
    chmod +x /usr/local/bin/mc

# dbx resolves its libraries as `$(dirname dbx)/lib`, so the launcher and lib/
# must live together. Keep the whole tree under /opt/dbx (on PATH) — it then runs
# exactly as it would from a source checkout, no path rewriting needed.
COPY dbx /opt/dbx/dbx
COPY lib/ /opt/dbx/lib/
COPY man/man1/ /usr/local/share/man/man1/
RUN chmod +x /opt/dbx/dbx
ENV PATH="/opt/dbx:${PATH}"

# State lives on mounted volumes; point dbx at stable in-container paths instead
# of $HOME so the operator only has to bind three dirs. `dbx serve` defaults to
# loopback; the container forces 0.0.0.0 via DBX_SERVE_BIND below so it is
# reachable in its own network namespace.
ENV DBX_CONFIG_DIR=/config \
    DBX_DATA_DIR=/data \
    DBX_AUDIT_DIR=/audit \
    DBX_SERVE_BIND=0.0.0.0 \
    DBX_SERVE_PORT=8080
RUN mkdir -p /config /data /audit
VOLUME ["/config", "/data", "/audit"]

EXPOSE 8080

# `docker run img` → `dbx serve`; `docker run img backup host db` also works.
ENTRYPOINT ["/opt/dbx/dbx"]
CMD ["serve"]
