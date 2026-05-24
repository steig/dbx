# PII scrub

A declarative manifest of every column that holds PII, plus a check that refuses to proceed when the live schema has columns the manifest doesn't know about. The manifest is the source of truth; `dbx scrub check` is how you keep it honest.

This is dbx's recommended path for masking PII at restore time. Hand-written [post-restore hooks](post-restore-hooks.md) still work for everything else, but for PII specifically the manifest gives you something hooks can't: an explicit, machine-readable answer to "what's in this database, and how is each piece being handled?"

## Why a manifest

A `scrub-pii.sql` file you hand-edited six months ago is a snapshot of the schema as it was six months ago. The day someone ships `users.recovery_email` or `accounts.tax_id_v2`, that file silently stops being correct. The next restore into staging quietly leaks the new column. There is no error. There is no warning. There is just unmasked PII in an environment that was supposed to be safe.

The manifest fixes this by declaring every PII-bearing column up front and then *checking* — every night in CI, and again immediately before each restore into a gated destination — that the live schema still matches what the manifest knows about. New column nobody declared? Drift. Restore aborts. CI turns red. Somebody updates the manifest.

The manifest is also the thing reviewers can read. "Show me every place we touch user data" is a `cat dbx.scrub.json` away.

## Quickstart

```bash
# 1. Walk the live schema and emit a draft manifest with suggested strategies.
dbx scrub init production > dbx.scrub.json

# 2. Read it. Override suggestions that look wrong. Add reasons to passthroughs.
$EDITOR dbx.scrub.json

# 3. Wire it into dbx.json.
#    "hosts": { "production": { "scrub": { "manifest": "dbx.scrub.json",
#                                          "required_for": ["staging", "local-dev"] } } }

# 4. Commit both files. The manifest is reviewable artifact, not a build output.
git add dbx.json dbx.scrub.json
git commit -m "Add PII scrub manifest for production"

# 5. Wire `dbx scrub check production` into your nightly CI.
```

From here on, every restore from `production` into a destination listed in `required_for` runs the drift check first, scrubs declaratively from the manifest, and verifies the scrub before handing you the clone.

## Config

The manifest is referenced from `dbx.json`, per host:

```jsonc
{
  "hosts": {
    "production": {
      "type": "postgres",
      "scrub": {
        "manifest": "dbx.scrub.json",
        "required_for": ["staging", "local-dev", "contractor-clone"]
      }
    }
  }
}
```

`manifest` is a path, resolved relative to the directory containing `dbx.json` (same rule as post-restore hook `file` entries). `required_for` is the list of destination host aliases that *must* go through the scrub when restoring from this source. A restore from `production` to `staging` runs the gate; a restore from `production` to `production-replica` doesn't unless you list it.

## Manifest schema

```jsonc
{
  "version": 1,
  "seed_env": "DBX_SCRUB_SEED",
  "dictionary": {
    "extend": ["mrn", "icd10"],
    "exclude": ["bitcoin_address"]
  },
  "tables": {
    "users": {
      "columns": {
        "email":         { "strategy": "fake_email" },
        "phone":         { "strategy": "fake_phone" },
        "ssn":           { "strategy": "redact" },
        "dob":           { "strategy": "shift_date", "max_days": 30 },
        "password_hash": { "strategy": "passthrough", "reason": "already opaque" }
      }
    },
    "support_tickets": {
      "columns": { "body": { "strategy": "truncate", "length": 40 } }
    },
    "user_metadata": {
      "columns": {
        "preferences": {
          "strategy": "jsonb_scrub_paths",
          "paths": {
            "$.contact.email": "fake_email",
            "$.contact.phone": "fake_phone"
          }
        }
      }
    },
    "audit_log": { "no_pii": true, "reason": "FKs only, no denormalized PII" }
  }
}
```

Field summary:

| Field | Purpose |
|---|---|
| `version` | Manifest schema version. Currently `1`. |
| `seed_env` | Name of the env var holding the salt for stable masking. The salt itself is never in the manifest. |
| `dictionary.extend` | Extra patterns to treat as PII for `init`/`check` suggestions. |
| `dictionary.exclude` | Built-in patterns to suppress (false positives). |
| `tables.<name>.columns` | Per-column strategy entries. |
| `tables.<name>.no_pii` | Affirmative "this table has no PII" marker. Requires a `reason`. |

!!! note "Seeds never live in the manifest"
    `seed_env` names the env var; the salt is read from `${!seed_env}` at scrub time. Committing the salt would defeat stable masking — anyone with the repo could re-derive the masked values back to plaintext for any column where the cleartext domain is small (emails, phones). Put the value in a secret store, not in git.

## The dictionary

`dbx scrub init` and `dbx scrub check` use a built-in dictionary of column-name patterns to *suggest* strategies. The matching rule is "normalize then substring-contain": each live column name is lowercased and stripped of `_` and `-`, then checked for substring containment against each pattern.

So `recovery_email` → `recoveryemail` matches `email`. `backup-phone` → `backupphone` matches `phone`. The bias is toward false positives — better to over-flag and let the human override than to miss a column.

Patterns currently in the built-in dictionary:

```
email, mail, phone, tel, mobile, fax,
ssn, socialsecurity, dob, birthdate, dateofbirth, birthday,
taxid, ein, vatnumber,
ccnumber, creditcard, cardnumber, pan, cvv, cvc,
passport, driverlicense, driverslicense,
address, addr, street, line1, line2, linea, lineb,
zip, zipcode, postcode, postalcode,
ipaddress, ipv4, ipv6,
password, passwordhash, passwd, pwd,
apikey, secret, token, accesstoken, refreshtoken,
firstname, lastname, fullname, givenname, familyname, middlename,
mrn, medicalrecordnumber
```

False positives get suppressed via `dictionary.exclude`. The substring rule means `bitcoin_address` matches `address`; if that's intentional in your schema (it's not PII in the regulatory sense), exclude it:

```jsonc
"dictionary": {
  "exclude": ["bitcoin_address"]
}
```

Domain-specific PII the dictionary doesn't ship with — `mrn` for healthcare, `icd10` for diagnosis codes, `studentid` for EdTech — extends in:

```jsonc
"dictionary": {
  "extend": ["mrn", "icd10", "studentid"]
}
```

Bare entries default to `redact`. To suggest a different strategy use `pattern:strategy` form (`"mrn:redact"`, `"birthday:shift_date:30"`).

## Strategies

| Strategy | Required params | What it does |
|---|---|---|
| `fake_email` | — | Replace with a deterministic fake email derived from the row PK and the seed. |
| `fake_phone` | — | Replace with a fake phone in the E.164-style `+1555NNNNNNN` shape. |
| `fake_ip` | — | Replace with a deterministic fake IPv4. |
| `fake_name` | — | Replace with a fake name. |
| `redact` | `replacement` (optional string) | Default: set the column to `NULL`. Set `replacement: ""` (or any literal) to write that value instead — required for `NOT NULL` columns so the UPDATE doesn't fail the gate. |
| `truncate` | `length` (positive int) | Keep the first `length` characters; drop the rest. Use for free-text columns where the *shape* matters but the contents shouldn't. |
| `shift_date` | `max_days` (positive int) | Shift the date by ± up to `max_days` days, deterministically per row. Preserves relative ordering coarsely; does not preserve referential time semantics. |
| `passthrough` | `reason` (non-empty string) | Explicit "this column is safe to copy verbatim". Required for password hashes, opaque tokens, anything where the *acknowledgement* is the value. |
| `jsonb_scrub_paths` | `paths` (object) | Rewrite specific JSON paths inside a `json`/`jsonb` column. See [JSON columns](#json-columns-implicit-deny) below. |

Fakes are deterministic in the row identity + the seed (`DBX_SCRUB_SEED` from `seed_env`). The same user gets the same fake email across every restore that uses the same seed — useful when your staging env keeps referential breadcrumbs (analytics, support tickets joined by email) but you can't carry the real address. Rotate the seed and every masked value changes.

!!! note "shift_date isn't cryptographic"
    The date shift is a weak sniff guard, not a privacy primitive. An attacker who knows an event happened in a one-week window and sees a shifted date can still narrow it back down. For columns where date proximity is itself sensitive (medical visits, financial transactions on a specific day), use `redact` and accept losing the time dimension.

## JSON columns: implicit-deny

Any `json` or `jsonb` column in a non-`no_pii` table **must declare a strategy**. There is no "we'll just assume the JSON is fine" path. JSON is where columns accumulate ad-hoc PII (`preferences.contact.email`, `metadata.legacy_ssn`) and not having a default opens exactly the silent-drift hole the manifest exists to close.

The three legal options:

1. **`jsonb_scrub_paths`** — rewrite specific paths inside the JSON. Paths use JSONPath-style notation. Each path maps to a leaf strategy (`fake_email`, `fake_phone`, `fake_ip`, `fake_name`, `redact`, `truncate`, `shift_date`; nested `jsonb_scrub_paths` is rejected).

    ```jsonc
    "preferences": {
      "strategy": "jsonb_scrub_paths",
      "paths": {
        "$.contact.email": "fake_email",
        "$.contact.phone": "fake_phone",
        "$.billing.last4":  "redact"
      }
    }
    ```

2. **`redact`** — replace the entire column with a fixed sentinel JSON value. Use when the column is opaque enough that no individual path is worth saving.

3. **`passthrough`** with a `reason` — explicit acknowledgement that the JSON is safe. Required for columns like `feature_flag_overrides` where the contents are knobs, not data about a person.

`dbx scrub init` samples the column when drafting the manifest and suggests `jsonb_scrub_paths` with the PII-looking paths it can see, so you don't have to write the path list from scratch.

## `dbx scrub check`

The drift check. Query the live schema, diff it against the manifest, exit with a status code:

| Exit code | Meaning |
|---|---|
| `0` | Clean. Manifest covers every column in the live schema. |
| `2` | Drift. New columns the manifest doesn't know about, or columns in the manifest that no longer exist in the schema. |
| `1` | Error (config invalid, can't connect, manifest malformed, etc.). |

```bash
dbx scrub check production
dbx scrub check production/myapp   # one DB instead of the whole host
```

Example drift output:

```
$ dbx scrub check production
[INFO] Reading manifest: dbx.scrub.json
[INFO] Querying live schema for production (1 db: myapp)
[WARN] Schema drift detected.

  New columns not in manifest (3):
    users.recovery_email                  suggested: fake_email
    users.backup_phone                    suggested: fake_phone
    accounts.tax_id_v2                    suggested: redact

  Columns in manifest but missing from schema (1):
    legacy_users.phone                    table no longer exists

  Tables with no declaration (1):
    feature_audit                         no_pii or columns required

Run `dbx scrub update production` to accept the suggestions above,
then commit dbx.scrub.json. Exit 2.
```

Exit 2 is the contract CI cares about. The standard wiring is a nightly job that runs `dbx scrub check production` against the real prod schema (read-only — `check` never writes); a failure pages whoever owns the manifest, who runs `dbx scrub update production`, reviews the diff, and merges the change.

```yaml
# .github/workflows/scrub-drift.yml — nightly drift check
on:
  schedule: [{ cron: "17 4 * * *" }]
jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: dbx scrub check production
        env:
          DBX_SCRUB_SEED: ${{ secrets.DBX_SCRUB_SEED }}
```

## Restore-time gate

When `<source>` has a scrub manifest and the restore destination is listed in `scrub.required_for`, dbx runs a four-step gate. The ordering matters:

1. **Pre-restore drift check.** Read the schema snapshot captured in the backup's `.meta.json` (added at backup time) and diff against the manifest. Drift here aborts the restore *before any data hits the local container* with exit 2. Legacy backups without the captured schema fall through to a post-restore check (same logic, applied after the engine restore — the target DB gets DROPPED on drift instead of never being created). New backups (taken on this version of dbx or later) always go the pre-restore path.

2. **Scrub.** Emit and run the SQL implied by the manifest, one column at a time, against the restored DB. If the host also has [post-restore hooks](post-restore-hooks.md), they run after the declarative scrub in the order they appear in `post_restore`.

3. **Sniff verification.** For each declared column, emit a `SELECT` that should return zero rows if the scrub worked (e.g. for `fake_email`: `SELECT 1 FROM users WHERE email !~ 'example\.test$' LIMIT 1`). Any column that comes back non-zero is a failed scrub.

4. **`scrub_report.json`.** Write a report next to the restore showing what ran and what passed.

If sniff verification fails, **the restored DB is dropped**. This inverts the policy of the [post-restore hooks](post-restore-hooks.md#behavior) feature, which leaves the partial DB in place for inspection. The reasoning is different: a hook that fails halfway is a debugging artifact, but a clone where scrub *thought* it succeeded and *didn't* is actively dangerous — leaving it on disk for someone to "just grab quickly" is exactly the leak the manifest exists to prevent. Drop it. Re-run after fixing.

To preview without committing, restore to a non-gated destination first; nothing is dropped because nothing was gated.

## `scrub_report.json`

Written next to the restore artifact after a gated restore. Format:

```jsonc
{
  "source_host": "production",
  "source_db": "myapp",
  "destination_host": "staging",
  "destination_db": "myapp_v1_20260523",
  "manifest_path": "dbx.scrub.json",
  "manifest_version": 1,
  "started_at": "2026-05-23T14:22:01Z",
  "finished_at": "2026-05-23T14:22:47Z",
  "columns": [
    { "table": "users", "column": "email",
      "strategy": "fake_email",
      "rows_modified": 14322, "verification": "pass" },
    { "table": "users", "column": "phone",
      "strategy": "fake_phone",
      "rows_modified": 14322, "verification": "pass" },
    { "table": "users", "column": "dob",
      "strategy": "shift_date", "max_days": 30,
      "rows_modified": 14322, "verification": "pass" },
    { "table": "support_tickets", "column": "body",
      "strategy": "truncate", "length": 40,
      "rows_modified": 92117, "verification": "pass" }
  ],
  "tables_no_pii": ["audit_log"],
  "overall": "pass"
}
```

Keep these as the audit trail for compliance reviews: every restore into a gated destination has one, every one says which seed was used (by name, never value), and `overall: pass` means the sniff queries all returned zero.

## Bootstrap with `dbx scrub init`

```bash
dbx scrub init production > dbx.scrub.json
dbx scrub init production --include-empty > dbx.scrub.json
```

`init` connects to the source, walks `information_schema.columns`, and for each column either:

- matches the built-in dictionary (or your `dictionary.extend` if you supply one) → emits a column entry with the suggested strategy, or
- doesn't match → leaves the column undeclared (the manifest will fail `check` until you decide).

`--include-empty` adds `{ "no_pii": true, "reason": "no dictionary matches at init" }` markers for every table with zero dictionary matches. Faster cold-start; you trade a longer initial review pass for not having to wade through `check` output. Without the flag, untouched tables show up as drift on the first `check` run and you decide one at a time.

The output is a *draft*. The expectation is that you read every line, override every suggestion you disagree with, and add `reason` fields to every `passthrough` and `no_pii` entry. `init` is a starting point, not an oracle.

## Iterating on the manifest

The [`--hooks-only` loop documented for post-restore hooks](post-restore-hooks.md#iterating-on-hook-scripts) works the same way for declarative scrub. Restore once into a non-gated destination to get a clone; tweak the manifest; re-run with `--hooks-only --name <existing-db>` against the same clone.

```bash
dbx restore production/myapp/latest --name myapp_scratch
# edit dbx.scrub.json
dbx restore production/myapp/latest --hooks-only --name myapp_scratch
```

Sniff verification still runs in `--hooks-only` mode. The drop-on-failure policy does not apply when the destination isn't gated; failures are reported and the clone is left for inspection, same as a hook failure.

## What this isn't

- **Not a row-level subsetter.** dbx still doesn't walk FK graphs to build referentially-consistent samples. For that, reach for [Neosync](https://www.neosync.dev/), [Tonic.ai](https://www.tonic.ai/), or a similar tool. The scrub manifest assumes you already have the rows you want; it only rewrites the values inside them. See [Subsetting dev clones](subsetting.md) for the patterns dbx supports natively.

- **Not NER on free-text.** `body`, `notes`, and `comments` columns get `truncate(N)` or `redact`. dbx will not attempt to find PII embedded inside English prose — that's a model, not a regex, and we are intentionally not shipping one. The *acknowledgement* (you wrote `{ "strategy": "truncate", "length": 40 }`) is the value: somebody decided what to do with this column.

- **Not a cryptographic guarantee on `shift_date`.** The shift is a weak sniff guard, not anonymization. See the note under [Strategies](#strategies).

- **No seed in the manifest.** `seed_env` only. Committing the salt would let anyone with repo access re-derive the masked values — for small cleartext domains (emails, phones) that's a full break. The manifest is reviewable; the seed is a secret.
