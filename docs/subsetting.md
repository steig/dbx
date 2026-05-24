# Subsetting your dev clone

A full prod clone is often too big to be useful for development. A 50 GB orders table is the same problem whether you're trying to fit it on your laptop, restore it quickly in CI, or hand it to a contractor.

dbx doesn't have a built-in row-level subsetting engine (yet — see [What this approach can't do](#what-this-approach-cant-do) below). But for the common 80% case — "drop noisy tables, keep recent rows" — a couple of [post-restore hooks](post-restore-hooks.md) get you most of the way at zero engineering cost.

## The cheapest pattern: truncate noisy tables

The biggest wins are usually `TRUNCATE`s. Session stores, audit logs, queued jobs, server-side analytics events — they're huge in prod and irrelevant in dev.

```sql
-- hooks/truncate-noise.sql
TRUNCATE sessions, login_attempts, audit_log, sidekiq_dead_jobs RESTART IDENTITY CASCADE;
```

`RESTART IDENTITY` resets the table's sequence so future inserts start from 1. `CASCADE` follows FKs — important when other tables reference the truncated ones, but read it carefully so you don't accidentally cascade-truncate something you wanted to keep.

Wire it in via config:

```json
{
  "hosts": {
    "production": {
      "post_restore": [
        { "file": "hooks/truncate-noise.sql" }
      ]
    }
  }
}
```

That alone often shrinks a clone by 80–90% when the bulk of the data is observability/queue tables.

## Time-windowed pruning

For tables where you want *some* recent data but not the full history — events, orders, notifications — delete everything older than a window:

```sql
-- hooks/keep-recent.sql
DELETE FROM events       WHERE created_at < NOW() - INTERVAL '7 days';
DELETE FROM notifications WHERE created_at < NOW() - INTERVAL '30 days';
DELETE FROM orders       WHERE created_at < NOW() - INTERVAL '90 days';
```

Pair with `VACUUM` if size on disk matters:

```sql
VACUUM FULL events, notifications, orders;
```

!!! note "MySQL caveat"
    `DELETE` inside a post-restore hook runs in the transaction wrap (`START TRANSACTION; … COMMIT;`). Large `DELETE`s in MySQL can be slow under InnoDB row-level locking — for tables with hundreds of millions of rows, the truncate pattern above is usually faster. `VACUUM FULL` doesn't exist in MySQL; use `OPTIMIZE TABLE`.

## Order matters — delete children before parents

If `orders.user_id → users.id` and you want to delete inactive users, you have to delete their orders first (or your hook hits a FK violation):

```sql
-- hooks/prune-inactive-users.sql
DELETE FROM order_items WHERE order_id IN (
  SELECT id FROM orders WHERE user_id IN (
    SELECT id FROM users WHERE last_sign_in_at < NOW() - INTERVAL '180 days'
  )
);
DELETE FROM orders WHERE user_id IN (
  SELECT id FROM users WHERE last_sign_in_at < NOW() - INTERVAL '180 days'
);
DELETE FROM users WHERE last_sign_in_at < NOW() - INTERVAL '180 days';
```

Two shortcuts that avoid the manual ordering:

- **Add `ON DELETE CASCADE` to your FKs.** Then `DELETE FROM users` propagates automatically. Best done in the source schema, but you can also alter the FK inside a hook before the prune.
- **Disable FKs for the duration of the hook.** Postgres: `SET session_replication_role = 'replica'; … DELETE …; SET session_replication_role = 'origin';`. MySQL: `SET foreign_key_checks = 0; … DELETE …; SET foreign_key_checks = 1;`. Faster for big prunes, but you're responsible for not leaving the DB in a referentially-inconsistent state.

## Combining with PII scrub

The natural pipeline is **subset first, mask second** — work on the smaller dataset. The recommended way to do the masking step is the declarative [PII scrub](scrub.md) manifest, which catches the schema-drift problem hand-written hook SQL silently has. Subset hooks run in array order before the manifest-driven scrub, so put the prune hooks first:

```json
"post_restore": [
  { "file": "hooks/truncate-noise.sql" },
  { "file": "hooks/keep-recent.sql" }
]
```

…with the scrub manifest wired in via the host's `scrub` block (see [PII scrub: Config](scrub.md#config)). The declarative scrub runs after `post_restore` finishes, so it only rewrites rows that survived the prune.

!!! note "If you haven't migrated yet"
    Hand-rolled `scrub-pii.sql` files still work as a third entry in `post_restore` — nothing forces you onto the manifest. But you give up drift detection and the sniff-verification gate, and you take on the silent-rot risk every time someone ships a new PII-bearing column. The manifest is the recommended path for new setups and the eventual migration target for existing ones.

## What this approach can't do

The post-restore-hooks pattern is great for **schema-level** pruning ("drop these tables entirely") and **time-windowed** pruning ("delete rows older than X"). It's a poor fit for **row-level FK-aware sampling** — "give me 1% of users and their referentially-connected orders, line items, addresses, etc."

That's the territory of [Neosync](https://www.neosync.dev/), [Jailer](http://jailer.sourceforge.net/), [Tonic.ai](https://www.tonic.ai/), and similar — tools that walk the FK graph from a seed set and build a referentially-consistent subset. dbx may grow this as a first-class feature in the future; for now, if you need it, reach for one of those alongside dbx.

The honest threshold: if a `TRUNCATE` + a few time-windowed `DELETE`s get your clone under your laptop's available disk, stay on the hook pattern. If you need to pull "all of company X's data and nothing else" from a multi-tenant DB while keeping FK consistency, you've outgrown what hooks can express.
