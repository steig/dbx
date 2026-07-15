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
ARG TARGETARCH=amd64
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc" \
        -o /usr/local/bin/mc \
    && chmod +x /usr/local/bin/mc

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
