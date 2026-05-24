# Boring integration — requirements for dbx

Source: [boring/docs/ards/ard-0012-dbx-restore-integration.md](https://github.com/steig/boring/blob/main/docs/ards/ard-0012-dbx-restore-integration.md)
Filed: 2026-05-24
Status: Proposed (boring blocks on this for its v0.5 slice; v1.0 release plan in [boring ARD-0008](https://github.com/steig/boring/blob/main/docs/ards/ard-0008-v03-to-v10-release-plan-and-thesis-evolution.md))

## Why

boring's v0.5 slice ships the `restore:` profile field, which lets a project declare "pipe this prod-shape data into my Postgres sidecar, sanitized." The flow is:

```yaml
# .boring/profile.yaml
restore:
  - source: dbx://prod/app-postgres
    target: postgres                  # compose service name → running container
    transform: ./scripts/sanitize.sql # strips PII at stream time
    when: on_first_up
data_sensitivity: sanitized           # forces transform: required
```

boring resolves the `target:` to the running compose-sidecar container, then invokes dbx to do the restore. The two requested features make that invocation possible without dbx writing unsanitized bytes to disk and without boring re-implementing the restore lifecycle.

## Feature 1 — `dbx restore --transform=<script>`

Streaming sanitization. The script is invoked with the restore byte-stream on stdin and is expected to emit the sanitized byte-stream on stdout. dbx pipes the restore output through it *before* any local disk write or downstream restore-into-target step. The security guarantee is **unsanitized bytes never touch disk**.

### Contract

- `<script>` is any executable on the host's PATH or an absolute path. dbx does not care about the language.
- Invocation: `<script>` is `exec`'d with stdin = the raw backup stream (e.g., pg_dump plain-SQL output) and stdout = the sanitized stream that dbx will then restore.
- Stream is unbounded; both dbx and the script must avoid buffering the entire dump (use `iter_lines` / line-buffered I/O; do not collect-then-process).
- Exit code: non-zero from the script aborts the restore. dbx must NOT have already written any partial sanitized data to the target. The whole operation fails atomically.
- stderr from the script is forwarded to dbx's stderr (visible to the operator for debugging).
- The script is run in a subprocess; environment is inherited from dbx's invocation (so the script can use credentials/config from env if needed).

### Scope limits (do NOT build)

- **Schema-aware transforms.** v1 is bytes-in-bytes-out. If the script wants to know "what table is this row from," it parses the SQL itself. dbx provides no introspection helpers.
- **Binary backup formats.** `--transform` requires plain SQL output from the source. Documented requirement: if `--transform` is set, dbx must invoke the upstream dump in plain-SQL mode (e.g., `pg_dump --format=plain`). Custom-format / tar-format dumps are incompatible with byte-stream transforms; error clearly if the user combines them.
- **A library of sanitize scripts.** Scripts are per-project, live in the project's repo, and are the project's responsibility. dbx doesn't ship templates.

### Acceptance test

- Given a Postgres source DB with a `users` table containing PII (`email`, `phone`), and a sanitize script that replaces those fields with `redacted@example.com` / `+1-555-0000`:
- `dbx restore <source> --transform=./sanitize.sql` produces a stream where the `users` rows have redacted values.
- The target DB receives the redacted rows.
- The unsanitized bytes are NOT written to any temp file (verify via `lsof` during restore, or by mounting `/tmp` as `tmpfs` and asserting no growth).
- If `sanitize.sql` is broken (exits non-zero mid-stream), the target DB receives nothing — no partial restore.

## Feature 2 — `dbx restore --into <container>`

Restore into a named running container instead of into a configured DSN. boring's compose-managed sidecars (named `postgres` within the compose project `boring-content-infra`, full docker name `boring-content-infra-postgres-1` or similar) are what boring wants dbx to target.

### Contract

- `<container>` is a docker container name as reported by `docker ps --format '{{.Names}}'`. Full name (including compose project prefix) required for disambiguation when multiple projects use the same service name.
- dbx queries the container via `docker inspect <container>` to extract connection details from its environment:
  - For postgres: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, plus the container's exposed port mapping.
  - Future engines (MySQL, etc.) are out of scope; document this and error clearly when `--into` targets a non-postgres container.
- Connection method (pick whichever is cleaner — boring doesn't care):
  - **Option A:** Connect from the host to the container's published port (`docker inspect` → `NetworkSettings.Ports`). Simpler but requires the container to publish the port (boring sidecars do).
  - **Option B:** `docker exec` into the container and run `psql` / `pg_restore` inside. No port-publishing required. Slightly heavier.
- Either way: dbx must wait for the container's database to be ready (poll with timeout, e.g., `pg_isready`). Containers may be up but DB still initializing.
- Error cases:
  - Container not running → clear error with name
  - Container running but no postgres env vars found → clear error explaining `--into` expects a postgres-shaped container
  - Container postgres not reachable within 30s → timeout error

### Scope limits

- **Postgres only initially.** MySQL / Mongo / Redis `--into` are out of scope; defer until a real use case appears (none exists in boring's profile set today).
- **`--into-db <name>` flag.** Default to `POSTGRES_DB` env var. If the user needs to target a different database within the same server, accept `--into-db <name>` as a future extension; not required for boring v1.0.

### Acceptance test

- Spin up a postgres:17 container with `POSTGRES_DB=test POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres` and published port.
- `dbx restore <source-backup> --into postgres17-test-container` populates the `test` database.
- Verify by `psql -h localhost -p <published-port> -U postgres -d test -c '\dt'` showing the restored tables.
- Repeat with the container stopped → expect clear error, no partial restore.

## The combined invocation

The boring use case always combines both flags:

```
dbx restore dbx://prod/app-postgres \
    --transform=./scripts/sanitize.sql \
    --into postgres-sidecar-container
```

Restore → pipe through `sanitize.sql` → restore the sanitized stream into the named container. The two flags must compose. Implement both, test the combination.

## Out-of-scope notes (boring side, for context)

- boring will NOT bundle dbx in its container images. dbx is a host-side runtime dependency ([boring ARD-0002](https://github.com/steig/boring/blob/main/docs/ards/ard-0002-dbx-as-runtime-dependency.md)). The host runs dbx; dbx targets the container via `--into`. Don't add a docker-image flavor of dbx for this.
- boring will manage the lifecycle of the sidecar container (compose up/down). dbx just needs to find a running named container and connect to it.
- boring will pass `--transform=<script-path>` where the script lives in the user's repo. dbx doesn't need to fetch or validate the script — just exec it.

## Suggested implementation order

1. `--transform` first (one PR). Smaller surface, mostly an addition to the existing restore pipeline.
2. `--into` second (separate PR). Touches connection-config resolution; bigger change.
3. Document both in dbx's `docs/restore.md` (or equivalent) with the combined example.
4. Update dbx's `--version` minimum that boring requires (boring's `boring doctor` will check this).

## Done definition

A boring profile with the `restore:` block above can run `boring open` → boring invokes `dbx restore ... --transform=... --into ...` → the sidecar comes up populated with sanitized data → operator runs `psql` inside the boring container against the sidecar and sees the redacted rows. End-to-end, no unsanitized bytes on disk, no manual intervention beyond `boring open`.

When that test passes, dbx is unblocked for boring v0.5.
