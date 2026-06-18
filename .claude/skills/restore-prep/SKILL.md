---
name: restore-prep
description: Scan a database for things that would break, leak, or fire side-effects when restored into a stage/dev clone, then generate the dbx PII scrub manifest + post-restore cleanup SQL hooks to make the clone safe. Use when the user wants to "prep a DB for restore", "figure out what to scrub", "generate cleanup hooks", "make a prod clone safe for stage", "scan for PII / restore issues", or is setting up a recurring stage refresh with dbx and needs to know what to cleanse. Produces a scrub manifest, post_restore hook SQL, config.json snippets, and a findings report — it proposes, the operator reviews and applies.
---

# Restore prep: scan a DB and generate cleanup artifacts

A logical restore of production into a stage/dev clone carries three hazards the operator
usually discovers the hard way:

1. **Leak** — real PII/secrets sitting in the clone (emails, names, phones, addresses, token
   columns, password hashes, PII inside JSON blobs).
2. **Side-effects** — config rows that point at real third parties, so the clone *acts on the
   world*: webhook/callback URLs, `base_url`/`site_url`, SMTP/from addresses, Stripe/payment
   keys, SMS/push provider keys, OAuth client secrets/redirect URIs, outbound S3 buckets.
3. **Runaway automation** — rows that make the clone *do work*: cron/scheduler tables, job
   queues (Sidekiq/Celery/Oban/pg-boss/Que), transactional-outbox rows pending dispatch,
   "send_at"/"run_at" columns with past timestamps.

Plus two operational nuisances: **oversized append-only tables** (logs/events/audit/sessions)
that make the clone slow and huge, and **auth state** (locked accounts, enforced SSO, unknown
admin passwords) that makes the clone hard to log into.

This skill scans the schema + samples a restored clone, then **generates** the dbx artifacts
that neutralize all of the above. It proposes; the operator reviews and applies.

## What it outputs

| Artifact | Path (suggested) | Consumed by |
|---|---|---|
| Extended PII scrub manifest | `scrub/<db>.scrub.json` | `hosts.<host>.scrub.manifest` + the restore scrub gate |
| Post-restore cleanup hooks | `hooks/<db>-stage-cleanup.sql` | `hosts.<host>.databases.<db>.post_restore[]` |
| Config snippets | inline in the report | the operator pastes into `config.json` |
| Findings report | inline (chat) | the human reviewer |

It does **not** edit `config.json` (it's canonical / version-controlled — the operator pastes
snippets) and it does **not** apply hooks to anything but the throwaway scan clone.

## Bundled tools (in this skill dir)

| File | Purpose |
|---|---|
| `fingerprint.sql` / `fingerprint-mysql.sql` | Detect the web framework(s) + ecosystem libs by signature tables. |
| `frameworks.md` | Per-framework playbook: where jobs / tokens / config / login state live, and how to neutralize each. |
| `deep-scan.sql` / `deep-scan-mysql.sql` | Recursively walk **every** JSON/JSONB column, classify nested secrets/PII by value-pattern + key-name (value-free output), sampled for speed. |
| `kv-scan-mysql.sql` | Scan **key/value config tables** (Magento `core_config_data`, WordPress `wp_options`, Django `constance_config`) for secrets — the surface JSON deep-scan can't reach. |

Run them against the restored **clone**, not the source. Use the plain files for a
PostgreSQL source and the `-mysql.sql` variants for a MySQL source (`mysql-dbx`).

## Why it scans a clone, not prod

`dbx query` is interactive-only (`docker exec -it`), so it can't be scripted. And prod is
`safety: prod` — read-only and not something to probe in a loop. Instead, restore one throwaway
clone into the managed `postgres-dbx` / `mysql-dbx` container and probe **that**:

- non-interactive SELECTs via `docker exec <container> psql/mysql` — no TTY needed
- `dbx scrub init` supports it directly via the `local/` pseudo-host
- it's exactly the DB the generated hooks will run against, so samples are representative
- it mirrors dbx's own `--hooks-only` hook-iteration loop

## Operating procedure

### 0. Establish the source and engine
Confirm `<host>/<db>` from the user (a host in their dbx config) and the engine
(`dbx config` / the host's `type`). Postgres and MySQL differ in probe SQL and hook SQL — emit
engine-correct output, never a blend.

### 1. Restore a throwaway scan clone
```bash
dbx restore <host>/<db>/latest --name <db>_scan --no-scrub
```
`--no-scrub` because the whole point is that no manifest exists yet; the clone is local,
throwaway, and never leaves the box. If a clone already exists you can reuse it. Record the
managed container name (`postgres-dbx` or `mysql-dbx`) and target DB (`<db>_scan`).

### 1b. Fingerprint the framework and load its playbook
```bash
# postgres source:
docker exec -i postgres-dbx psql -U postgres -d <db>_scan < fingerprint.sql
# mysql source:
docker exec -i mysql-dbx mysql -u root -p<pw> <db>_scan < fingerprint-mysql.sql
```
For every framework reported `PRESENT`, open **`frameworks.md`** and apply that section — it
names the exact jobs / token / config / login tables for Django, Rails, Laravel, Node
(Auth.js, pg-boss, graphile-worker), Spring/Quartz, WordPress, Supabase. This is what makes
the scan find framework-specific surfaces (e.g. `social_auth_*.extra_data` tokens, Doorkeeper
`oauth_access_tokens`, Auth.js `accounts.refresh_token`, Quartz `qrtz_triggers`) that generic
regex would miss. A schema can match several frameworks — apply all of them. The framework also
dictates the **password hasher** for the login-reset REVIEW item (Django pbkdf2/bcrypt_sha256,
Rails/Laravel bcrypt, WP phpass) — never a generic `crypt()`.

### 2. Get the PII baseline from dbx
```bash
dbx scrub init local/<db>_scan --output scrub/<db>.scrub.json
```
This walks `information_schema` and dictionary-matches column names → a draft manifest. Treat it
as the floor, not the ceiling: it catches `email`, `phone`, `ssn`-shaped names but misses
domain-specific PII (`contact_blob`, `notes`, `shipping_json`, `legacy_ref`) and PII buried in
JSON/JSONB. You will extend it.

### 3. Probe the clone for what the dictionary can't reason about
Run these read-only against the clone. **Postgres** (`docker exec postgres-dbx psql -U postgres -d <db>_scan -c "<sql>"`):

```sql
-- 3a. Outbound / side-effect config columns (URLs, endpoints, secrets, provider keys)
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema='public'
  AND (column_name ~* '(url|uri|endpoint|webhook|callback|redirect|host|domain'
       || '|secret|token|api[_-]?key|client[_-]?secret|password|passwd|pwd'
       || '|smtp|mailer|from[_-]?(email|addr)|stripe|paypal|twilio|sendgrid'
       || '|aws|s3|bucket|access[_-]?key)')
ORDER BY table_name, column_name;

-- 3b. Automation rows that would fire in stage
SELECT table_name FROM information_schema.tables
WHERE table_schema='public'
  AND table_name ~* '(cron|schedul|job|queue|worker|sidekiq|oban|que_|pg_boss'
      || '|outbox|webhook|notification|email|delivery|dispatch|event)'
ORDER BY table_name;

-- 3c. Oversized append-only tables (volume) — biggest relations
SELECT relname, n_live_tup,
       pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 25;

-- 3d. Feature flags / entitlements / settings tables
SELECT table_name FROM information_schema.tables
WHERE table_schema='public'
  AND table_name ~* '(feature|flag|toggle|entitlement|setting|config|plan|subscription)'
ORDER BY table_name;

```

**MySQL** equivalents: swap `information_schema.columns` with `WHERE table_schema=DATABASE()`,
use `column_name REGEXP '...'` (MySQL has no `~*`), and for sizes query
`information_schema.tables` (`DATA_LENGTH+INDEX_LENGTH`, `TABLE_ROWS`).

### 3f. Deep JSONB scan — the part that finds NESTED secrets
The column-name probes above only see top-level columns. Secrets routinely hide *inside* JSON
(e.g. a service-account key nested at `<settings>.credentials.private_key`, a payment secret at
`<orders>.metadata.payment_intent_client_secret`, provider passwords at
`<integration>.settings.password`). Run the bundled recursive scanner — it walks every
JSON/JSONB column (objects + arrays) and classifies leaf strings by **value-pattern** (PEM
private keys, `sk_live`/`pk_`, `xox*`, `AIza*`, `gh*_`, `shpat_`, JWT, `://user:pass@`) and by
**key-name**, emitting only `(table, column, path_template, category, hits)` — never values:
```bash
# postgres source:
docker exec -i postgres-dbx psql -U postgres -d <db>_scan -v sample=500 < deep-scan.sql
# mysql source (override sample via --init-command="SET @sample=500"):
docker exec -i mysql-dbx mysql -u root -p<pw> <db>_scan < deep-scan-mysql.sql
```
Sampling is per-column (`:sample` rows, default 500) so it stays fast on 384k-row product-JSON
tables; coverage (scanned/total) is printed so the cap is never silent — raise `sample` if a
big table might hide rare secrets. The `path_template`s it prints are exactly what you declare
as `jsonb_scrub_paths` in the manifest or strip in the hook. Ignore the `high_entropy_token_like`
bucket's volume (it's mostly product hashes/ids); trust the named categories. Value patterns
are anchored, so a secret embedded *mid-string* in a larger value (e.g. `"contact a@b.com now"`)
classifies as `other` — a detection miss, not a leak (values are never emitted).

> **Engine support.** Postgres uses `fingerprint.sql` + `deep-scan.sql` (recursive CTE).
> MySQL 8+ uses `fingerprint-mysql.sql` + `deep-scan-mysql.sql` (the deep scan walks JSON
> iteratively via a worklist procedure, since MySQL recursive CTEs can't do the lateral JSON
> expansion). Same value-free output contract on both engines.

### 3g. Key/value config scan — secrets that aren't in JSON
Some stacks keep secrets in a key/value config **table**, which neither the column-name probes
nor the JSON deep-scan will catch: Magento `core_config_data` (carrier/payment passwords, AWS
keys, API secrets), WordPress `wp_options`, Django `constance_config`. Run:
```bash
# mysql source:
docker exec -i mysql-dbx mysql -u root -p<pw> <db>_scan < kv-scan-mysql.sql
```
It classifies each config row by key-name + value-pattern (value-free) and prints the secret
key paths to repoint/blank in the hook. The registry at the top lists the tables it knows; add a
`(table, key_col, value_col)` row for any other key/value config table you find. (A Postgres
`constance_config`/`wp_options` equivalent isn't bundled yet — fold those paths into the manifest
or hook by hand on PG.)

For any column 3a/3e flags, confirm before acting by sampling — but **redact** (see Safety):
```sql
-- confirm a column holds URLs/secrets WITHOUT printing the values
SELECT count(*) total, count(DISTINCT <col>) distinct_vals,
       max(length(<col>)) maxlen,
       count(*) FILTER (WHERE <col> ~* '^https?://') looks_url
FROM <table>;
```

### 4. Reason and bucket every finding
For each flagged table.column, decide **one** action and a confidence:

| Category | Action | Goes to |
|---|---|---|
| Real PII (confirmed) | scrub | manifest |
| Possible PII (ambiguous, or app may depend on it) | **REVIEW** | report only |
| Outbound URL / endpoint | rewrite to stage/localhost | hook |
| Secret / provider key / OAuth secret | null or set to obvious-dummy | hook |
| Cron / scheduler row | disable (`enabled=false`) or delete | hook |
| Job-queue / outbox pending rows | delete | hook |
| Past `run_at`/`send_at` | null or push far future | hook |
| Feature flag / entitlement | reset to stage defaults | hook (REVIEW the values) |
| Admin/login auth | reset password to known dev value, unlock, drop SSO enforce | hook (REVIEW) |
| Oversized append-only | exclude at backup, or `TRUNCATE` in hook | config `exclude_data` + report |

Anything you are not confident about does **not** silently land in a hook — it goes to the
REVIEW bucket with the reason ("nulling `users.api_token` may break the API-client test suite —
confirm").

### 5. Emit the artifacts

**Extend the manifest** (step 2's file) with the confirmed-PII columns the dictionary missed,
including JSON paths. Match the schema dbx's `scrub init` emitted (don't invent a shape — open
the generated file and follow it). Validate: `dbx scrub validate <host>` after wiring, or
`dbx scrub check local/<db>_scan --manifest scrub/<db>.scrub.json` (exit 0 = manifest covers the
live schema, exit 2 = drift).

**Write the cleanup hook** as engine-correct, **idempotent** SQL (it re-runs on every refresh).
dbx binds these vars into every hook: `target_db`, `source_host`, `source_db`, `backup_file`,
`backup_timestamp`, `restored_at` — Postgres via `psql -v` (reference as `:'target_db'`), MySQL
via session vars (`@target_db`). Postgres runs each hook under `psql -1` (atomic); MySQL wraps in
a txn but **DDL implicitly commits** — keep MySQL hooks pure-DML or document the risk. Example shape:

```sql
-- hooks/<db>-stage-cleanup.sql  (postgres)
-- Repoint outbound config so the clone can't act on the world.
UPDATE site_config SET base_url = 'https://stage.example.com'
WHERE base_url IS NOT NULL;
UPDATE integrations SET webhook_url = NULL, api_secret = NULL;
-- Stop automation from firing.
UPDATE scheduled_jobs SET enabled = false;
DELETE FROM job_queue;            -- pending background work
DELETE FROM event_outbox WHERE dispatched_at IS NULL;
-- Make the clone loginable (REVIEW with operator). Do NOT use a generic crypt() —
-- the value must be a hash the app's framework accepts. Look up the hasher in
-- frameworks.md (Django pbkdf2/bcrypt_sha256/argon2, Rails/Laravel bcrypt, WP phpass)
-- and set a precomputed known-password hash, or run the framework's own reset
-- (e.g. Django `manage.py changepassword`) as a separate post-step.
UPDATE users SET locked_at = NULL WHERE is_admin = true;  -- unlock only; set hash per framework
```

**Config snippets** for the operator to paste. Everything lives under `hosts.<host>` — the
scrub gate at the host level, hooks + data exclusions per database:
```jsonc
"hosts": {
  "<host>": {
    // Gate restores on a clean scrub: a schema-drift check runs before the engine
    // restore and aborts if the live schema has PII columns the manifest misses.
    "scrub": { "required": true, "manifest": "scrub/<db>.scrub.json" },
    "databases": {
      "<db>": {
        "post_restore": [ { "file": "hooks/<db>-stage-cleanup.sql" } ],
        // optional: keep the clone small — schema is kept, data is skipped per table.
        "exclude_data": ["audit_log", "events", "sessions"]
      }
    }
  }
}
```
(`post_restore` also works host-wide at `hosts.<host>.post_restore[]`, which runs before the
per-db hooks. Each entry is exactly one of `{ "file": "..." }` or `{ "sql": "..." }`.)

### 6. Verify, then clean up
```bash
# manifest covers the schema (no undeclared PII columns)
dbx scrub check local/<db>_scan --manifest scrub/<db>.scrub.json

# iterate the hook against the clone without a full re-restore
dbx restore <host>/<db>/latest --name <db>_scan --hooks-only

# when satisfied, drop the throwaway clone
docker exec postgres-dbx psql -U postgres -c 'DROP DATABASE IF EXISTS "<db>_scan" WITH (FORCE)'
```
End by telling the operator exactly which files to review (manifest + hook), which snippets to
paste, and which findings are in the **REVIEW** bucket awaiting their decision.

## Safety rules (non-negotiable)

- **Read-only against the clone; never touch the source.** The only writes are to the throwaway
  `<db>_scan` and to the artifact files.
- **Never write real PII/secret values** into the manifest, hooks, report, or chat. Describe
  columns and patterns; when sampling to confirm, use counts/lengths/regex-flags, not raw
  values. A findings report that quotes a real email has itself become a leak.
- **Don't auto-scrub anything load-bearing.** A column the app joins/filters on, or a token a
  test suite needs, goes to REVIEW — nulling it breaks the clone in a way that looks like a dbx
  bug. When unsure, surface it; don't decide.
- **Hooks must be idempotent and engine-correct.** They run on every scheduled refresh. Mind the
  MySQL DDL-implicit-commit caveat.
- **Propose, don't apply.** No edits to `config.json`; no hooks run anywhere but the scan clone.

## Notes / future

- This skill is the manual, agent-driven version of what could become a `dbx restore-scan`
  subcommand. `fingerprint.sql` + `deep-scan.sql` are the seed for that — they already emit
  structured, value-free output; promoting them into `lib/` with a JSON mode the skill (or CI)
  consumes is the natural next step.
- `frameworks.md` is the part to keep growing: when the scan meets a stack not yet covered
  (or a new jobs/auth library), add its signature tables to `fingerprint.sql` and a row to the
  relevant `frameworks.md` section so the next run recognizes it by name.
- For pure dictionary PII with drift detection, `dbx scrub init/check` already exists — this
  skill exists for the judgment the dictionary can't do and for the operational hooks dbx has no
  generator for.
