# Cloud-hosted Postgres

Amazon RDS and Aurora, Google Cloud SQL, Neon, Supabase, and CockroachDB
all speak the PostgreSQL wire protocol. That means dbx already backs them
up through the existing `type: postgres` path — `pg_dump`/`pg_restore`
run inside the managed `postgres-dbx` container and connect out to the
provider exactly the way they would to any other Postgres server. There
is no separate engine or provider setting; the only thing that differs
per provider is *how you reach the database* (direct vs. SSH tunnel) and
*how you supply credentials*.

This page collects connection recipes for the common managed providers.
For the underlying config schema see [Configuration](configuration.md);
for credential handling see [Credential storage](credentials.md).

## How dbx connects

dbx offers two network modes per host (see the
[per-host options](configuration.md#per-host-options)):

| Mode | Config keys | When to use |
|------|-------------|-------------|
| Direct | `host`, `port` | The DB is reachable from the machine running dbx (public endpoint, VPN, or same network). |
| SSH tunnel | `ssh_tunnel.{jump_host, target_host, target_port}` | The DB lives in a private subnet/VPC and is only reachable through a bastion. dbx opens the tunnel, points `pg_dump` at it, and tears it down on exit. |

`pg_dump` runs as `--username=<user>` with the password sourced from the
vault (or `password_cmd`), so credential setup is the same regardless of
provider:

```bash
dbx vault set <host>     # prompts for the DB password, stores it in the system vault
```

!!! note "TLS / `sslmode`"
    dbx does not expose a per-host `sslmode` setting. In **SSH-tunnel
    mode** the database connection rides inside the encrypted SSH
    channel from the bastion, so transport is already protected and the
    provider sees a connection originating from inside its own
    network. For **direct connections** to a public endpoint, dbx relies
    on libpq's default negotiation — most managed providers accept (and
    many default to) TLS. If a provider *requires* verified TLS on its
    public endpoint and a direct connect is refused, prefer the
    SSH-tunnel-to-a-bastion recipe below, which avoids exposing the
    database publicly at all.

## Amazon RDS / Aurora (PostgreSQL)

RDS and Aurora instances normally live in a private subnet. Put a bastion
(an EC2 host, or any SSH box with network access to the instance) in the
same VPC and tunnel through it. `target_host` is the RDS/Aurora endpoint
as resolved *from the bastion*.

```json
{
  "hosts": {
    "rds-prod": {
      "type": "postgres",
      "user": "backup_user",
      "safety": "prod",
      "ssh_tunnel": {
        "jump_host": "ec2-user@bastion.example.com",
        "target_host": "myapp.abcdef123456.us-east-1.rds.amazonaws.com",
        "target_port": 5432
      },
      "databases": {
        "myapp": { "exclude_data": ["sessions", "audit_log"] }
      }
    }
  }
}
```

```bash
dbx vault set rds-prod        # store the backup_user password
dbx test rds-prod             # verify the tunnel + connection
dbx backup rds-prod
```

!!! tip "Short-lived IAM credentials"
    RDS supports IAM authentication tokens in place of a static
    password. Generate the token on demand with `password_cmd` instead of
    storing a password in the vault:

    ```json
    "password_cmd": "aws rds generate-db-auth-token --hostname $RDS_ENDPOINT --port 5432 --username backup_user --region us-east-1"
    ```

    dbx invokes the command once per operation, so each run gets a fresh
    token.

If your RDS instance has a public endpoint and is reachable directly,
drop `ssh_tunnel` and use `host`/`port` instead:

```json
"rds-prod": {
  "type": "postgres",
  "user": "backup_user",
  "host": "myapp.abcdef123456.us-east-1.rds.amazonaws.com",
  "port": 5432
}
```

## Google Cloud SQL (PostgreSQL)

The cleanest path is the [Cloud SQL Auth
Proxy](https://cloud.google.com/sql/docs/postgres/sql-proxy): run it on a
bastion (or anywhere dbx can reach), and it presents the instance on a
local port. Point dbx at that.

- **Proxy on a bastion** — tunnel to the bastion, with the proxy
  listening on `localhost:5432` there:

  ```json
  "cloudsql-prod": {
    "type": "postgres",
    "user": "backup_user",
    "ssh_tunnel": {
      "jump_host": "user@bastion.example.com",
      "target_host": "localhost",
      "target_port": 5432
    }
  }
  ```

- **Proxy on the same machine as dbx** — connect directly:

  ```json
  "cloudsql-prod": {
    "type": "postgres",
    "user": "backup_user",
    "host": "127.0.0.1",
    "port": 5432
  }
  ```

Store the Cloud SQL user's password with `dbx vault set cloudsql-prod`.

## Neon

Neon exposes a public TLS endpoint, so a direct connection works. Use the
host from your Neon connection string and the role as `user`.

```json
"neon-prod": {
  "type": "postgres",
  "user": "myapp_owner",
  "host": "ep-cool-name-123456.us-east-2.aws.neon.tech",
  "port": 5432,
  "databases": {
    "myapp": {}
  }
}
```

```bash
dbx vault set neon-prod
dbx backup neon-prod
```

!!! note "Neon pooler vs. direct endpoint"
    Use Neon's **direct** (non-pooled) endpoint for backups. The pooled
    endpoint (the `-pooler` host) runs in transaction-pooling mode, which
    `pg_dump` is not designed to run through. The direct host is the one
    without `-pooler` in the name.

## Supabase

Supabase is managed Postgres with a public endpoint. Use the database
connection details from **Project Settings → Database** (not the API
keys). The role is typically `postgres`.

```json
"supabase-prod": {
  "type": "postgres",
  "user": "postgres",
  "host": "db.abcdefghijklmnop.supabase.co",
  "port": 5432,
  "databases": {
    "postgres": { "exclude_data": ["storage.objects"] }
  }
}
```

```bash
dbx vault set supabase-prod
dbx backup supabase-prod
```

!!! note "Direct vs. pooled connection"
    Like Neon, Supabase offers a connection pooler (Supavisor) alongside
    the direct connection. Back up through the **direct** connection
    (port `5432`), not the pooler's transaction-mode port (`6543`) —
    `pg_dump` needs a session-mode connection.

## CockroachDB

CockroachDB speaks the Postgres wire protocol and works with the
`type: postgres` path, but it is *not* byte-for-byte PostgreSQL.
`pg_dump` against CockroachDB has known caveats:

- CockroachDB recommends its own
  [`cockroach dump`](https://www.cockroachlabs.com/docs/) /
  cluster-backup tooling for full-fidelity backups. `pg_dump` captures
  table data and most schema, but CockroachDB-specific features
  (interleaved tables, certain index/constraint forms, region/locality
  settings) may not round-trip cleanly.
- Restoring a `pg_dump`-produced archive into a *PostgreSQL* container
  (dbx's default `postgres-dbx`) — rather than back into CockroachDB —
  can hit incompatibilities for any SQL that is CockroachDB-only.
- Prefer `--format=plain`-style logical dumps you can inspect when
  validating compatibility, and **always test a restore** before relying
  on a CockroachDB backup taken this way.

Treat dbx's CockroachDB support as "logical export of standard SQL via
the pg wire protocol," suitable for schemas that stay within the
Postgres-compatible subset. For everything else, use Cockroach's native
backup tooling.

A typical config still looks like any other host (direct or tunneled):

```json
"crdb-prod": {
  "type": "postgres",
  "user": "backup_user",
  "host": "myapp.crdb.example.com",
  "port": 26257
}
```

Note CockroachDB's default SQL port is `26257`, not `5432`.

## Verifying any provider

Whatever the provider, the workflow is the same once the host is
configured:

```bash
dbx test <host>      # prove credentials + network reach the DB
dbx backup <host>    # take a backup
dbx restore <host>   # restore into a sandboxed local container to verify
```

If a connection fails, check (in order): the credential is in the vault
(`dbx vault get <host>`), the network mode matches reality (tunnel vs.
direct), and — for tunnels — that the bastion can itself reach
`target_host:target_port`.
