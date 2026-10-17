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

# MinIO client for `dbx storage` S3 offload, built from source. Alpine's `mc`
# package is Midnight Commander, not MinIO, and MinIO no longer ships prebuilt
# binaries: every dl.min.io URL returns 410 Gone and the Docker Hub / quay.io
# images are gone (#259). The archived minio/mc repo on GitHub still has the
# source.
#
# Pinned to the commit behind tag RELEASE.2025-08-13T08-35-41Z, the release the
# image shipped before. Fetching by full SHA (and re-checking it) pins the
# source; `-mod=readonly` makes `go build` check every module against go.sum.
# Bump MC_RELEASE and MC_COMMIT together, deliberately.
#
# The stage runs on the build host (--platform=$BUILDPLATFORM) and cross-compiles
# for TARGETARCH, so the arm64 image doesn't compile Go under QEMU.
#
# TARGETARCH is declared bare on purpose. `ARG TARGETARCH=amd64` does NOT mean
# "amd64 unless building for something else" — the default shadows the value
# BuildKit injects, so every arch resolved to amd64 and the published arm64
# image carried an amd64 mc that could not execute. Without a default, a build
# that doesn't supply it (legacy non-BuildKit builder) falls into the case
# below and fails loudly instead.
FROM --platform=$BUILDPLATFORM golang:1.23-alpine3.20 AS mc
ARG TARGETARCH
ARG MC_RELEASE=RELEASE.2025-08-13T08-35-41Z
ARG MC_COMMIT=7394ce0dd2a80935aded936b09fa12cbb3cb8096
RUN apk add --no-cache git
WORKDIR /src
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64|arm64) ;; \
      *) echo "no mc build for TARGETARCH='$TARGETARCH'" >&2; exit 1 ;; \
    esac; \
    git init -q .; \
    git fetch -q --depth 1 https://github.com/minio/mc.git "$MC_COMMIT"; \
    git checkout -q FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "$MC_COMMIT"; \
    CGO_ENABLED=0 GOOS=linux GOARCH="$TARGETARCH" GOTOOLCHAIN=local GOFLAGS=-mod=readonly \
      go build -trimpath -tags kqueue \
        -ldflags "-s -w -X github.com/minio/mc/cmd.ReleaseTag=${MC_RELEASE} -X github.com/minio/mc/cmd.CommitID=${MC_COMMIT}" \
        -o /out/mc .

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

COPY --from=mc /out/mc /usr/local/bin/mc

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
