# AI-assisted restore prep

`dbx scrub init` finds PII by matching column *names* against a dictionary. That's the right
baseline, but it can't reason: it misses secrets nested inside JSON, secrets in key/value config
tables, and it has no idea which rows would make a clone *act on the world* (fire webhooks, send
email, run cron). It also can't write the operational cleanup for you.

The **`restore-prep` skill** fills that gap. It's a [Claude Code](https://claude.com/claude-code)
skill that ships with dbx (in `.claude/skills/restore-prep/`). Pointed at a restored clone, it
scans for secrets/PII the dictionary misses, recognizes your application framework, and
**generates** the two artifacts that make a clone safe for staging:

- an extended [PII scrub manifest](scrub.md) (`scrub/<db>.scrub.json`), and
- a [post-restore cleanup hook](post-restore-hooks.md) (`hooks/<db>-stage-cleanup.sql`).

It *proposes*; you review and wire it in. It never edits `config.json` and never touches your
source database.

!!! note "This is an AI agent workflow, not a `dbx` subcommand"
    The skill runs inside Claude Code. There is no `dbx restore-scan` command (yet). Open this
    repo in Claude Code and ask it to "prep `<host>/<db>` for restore", or invoke the skill
    directly. The SQL probes it uses are plain files you can also run by hand (below).

## Why a clone, not prod

The skill works against a **restored clone** in dbx's managed container, never prod:

- prod is `safety: prod` (read-only) and not something to probe in a loop;
- the clone is queryable non-interactively and is exactly what the generated hooks will run
  against, so its findings are representative;
- it mirrors dbx's own [`--hooks-only`](restore.md) hook-iteration loop.

## What it scans

| Layer | Tool | Finds |
|---|---|---|
| Framework | `fingerprint.sql` (Postgres) / `fingerprint-mysql.sql` (MySQL) | Common to both: Django, Rails, Laravel, Spring/Quartz. Postgres-only: Supabase, pg-boss, graphile-worker. MySQL-only: WordPress, Magento, WooCommerce, PrestaShop, OpenCart. |
| Nested JSON | `deep-scan.sql` (Postgres) / `deep-scan-mysql.sql` (MySQL) | secrets/PII *inside* JSON/JSONB — private keys, `sk_live`/`AKIA`/`xox`/JWT, `://user:pass@`, emails — at any depth |
| Key/value config | `kv-scan-mysql.sql` (**MySQL only**) | secrets in config tables (Magento `core_config_data`, WordPress `wp_options`). Django `constance_config` is covered only on MySQL-backed Django; on Postgres there's no bundled kv-scan yet — fold those paths into the manifest by hand. |

For each framework it detects, the bundled `frameworks.md` playbook says where that stack hides
jobs, tokens, config, and login state — so the generated hook disables the right cron/queue
tables, clears the right token tables, and repoints the right URLs, by name.

## Safety properties

- **Value-free.** The scans emit *locations and classifications* — `(table, column, path, category, count)` — never the secret values themselves. A report that quoted a real key would itself be a leak.
- **Read-only on the clone.** The only writes are to the throwaway scan clone and to the artifact files it proposes.
- **Propose, don't apply.** No edits to `config.json`; nothing runs against anything but the clone. Ambiguous findings (a column the app may depend on, a login-password reset) go to a **REVIEW** bucket for you to decide.
- **Framework-correct.** Login-password resets use the app's actual hasher (Django pbkdf2/bcrypt_sha256, Rails/Laravel bcrypt, WP phpass) — never a generic `crypt()` that produces an unusable hash.

## Workflow

```bash
# 1. Restore a throwaway scan clone (local; never touches prod)
dbx restore <host>/<db>/latest --name <db>_scan --no-scrub

# 2. Open this repo in Claude Code and run the restore-prep skill against <host>/<db>.
#    It will: fingerprint the framework, deep-scan JSON + key/value config, then write
#    scrub/<db>.scrub.json and hooks/<db>-stage-cleanup.sql for you to review.

# 3. Verify
dbx scrub check local/<db>_scan --manifest scrub/<db>.scrub.json
# --hooks-only runs the hooks CONFIGURED for <host>/<db>, so wire the generated file
# into config.json (step 4) first, then use this to iterate it against the clone:
dbx restore <host>/<db>/latest --name <db>_scan --hooks-only

# 4. Wire the reviewed artifacts into config.json (scrub gate + post_restore), then drop the clone
```

Running the probes by hand (without the agent) is also fine — they're ordinary SQL:

```bash
docker exec -i postgres-dbx psql -U postgres -d <db>_scan < .claude/skills/restore-prep/deep-scan.sql
docker exec -i mysql-dbx mysql -u root -p<pw> <db>_scan < .claude/skills/restore-prep/deep-scan-mysql.sql
```

## Relationship to the built-in features

This skill **complements** dbx's first-class features, it doesn't replace them:

- [PII scrub](scrub.md) — the manifest + drift-check + fail-closed gate. The skill *generates and extends* the manifest; dbx enforces it.
- [Post-restore hooks](post-restore-hooks.md) — dbx runs the hook the skill writes after every restore, in a transaction.
- [Subsetting](subsetting.md) — for trimming oversized tables out of the clone.

The division of labor: dbx provides the safe, declarative *enforcement*; the skill provides the
*judgment* to author what gets enforced.
