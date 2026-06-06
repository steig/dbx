# Framework playbooks

Per-framework map of where automation, credentials, config, and login state live — so
restore-prep targets the *right* tables by name instead of hoping regex finds them.
Run `fingerprint.sql` first; for every framework it reports PRESENT, apply that section.
A schema can match several (hybrid apps) — apply all that match.

Generic rules that apply everywhere:
- **Jobs/schedulers** → disable (don't just delete) where there's an enabled flag; delete
  pending/queued rows. A clone must do no background work.
- **Token/credential tables** → `DELETE`/`TRUNCATE` (they're prod-issued; the app re-issues).
- **Config tables** → repoint outbound URLs, blank provider secrets (deep-scan finds the paths).
- **Login** → reset/blank passwords via the framework's hasher, never a generic `crypt()`.
- Many frameworks keep real secrets in **ENV / encrypted files, not the DB** (Rails
  `credentials.yml.enc`, Laravel `.env`, Spring `application.yml`). Note that — the DB scrub
  doesn't cover those, the deploy does.

---

## Django  (fingerprint: `django_migrations`, `django_content_type`)

| Concern | Tables | Action |
|---|---|---|
| Celery beat schedules | `django_celery_beat_periodictask` (+ `_crontabschedule`, `_intervalschedule`, `_clockedschedule`, `_solarschedule`) | `UPDATE django_celery_beat_periodictask SET enabled=false` |
| Celery results | `django_celery_results_taskresult`, `_chordcounter`, `_groupresult` | `TRUNCATE` (noise/PII in args) |
| django-extensions cron | `scheduler_cronjob`, `scheduler_repeatablejob`, `scheduler_scheduledjob` | `UPDATE scheduler_cronjob SET enabled=false` |
| django-q | `django_q_schedule`, `django_q_task`, `django_q_ormq` | delete `ormq`/`task`; null `schedule.next_run` |
| DRF API tokens | `authtoken_token` | `DELETE` |
| OAuth/social tokens | `social_auth_usersocialauth` (`.extra_data` JSON has access/refresh), `socialaccount_socialtoken` (allauth), `oauth2_provider_accesstoken`/`_refreshtoken` (oauth-toolkit) | `DELETE` token tables |
| Dynamic config | `constance_config` (key/value, secrets common), any custom settings/JSON table | deep-scan + repoint/blank |
| Feature flags | `waffle_flag`, `waffle_switch`, `waffle_sample` | reset to stage defaults (REVIEW) |
| Canonical URLs | `django_site` (`domain`) | `UPDATE django_site SET domain='stage…'` |
| Sessions | `django_session` | `TRUNCATE` (volume + hijack risk) |
| PII / login | `auth_user` (`email`,`first_name`,`last_name`,`password`), custom user model | scrub via manifest; password uses Django hasher (pbkdf2 / **bcrypt_sha256** / argon2) — set a known hash or `manage.py changepassword`, never `crypt()` |

## Rails / ActiveRecord  (fingerprint: `ar_internal_metadata`, `schema_migrations`)

| Concern | Tables | Action |
|---|---|---|
| Jobs | `good_jobs`, `delayed_jobs`, `solid_queue_*`, `que_jobs` | `TRUNCATE` queued; pause recurring (`good_job_settings`, `solid_queue_recurring_tasks`) |
| Storage | `active_storage_blobs`/`_attachments` | leave (data) unless volume |
| OAuth (Doorkeeper) | `oauth_access_tokens`, `oauth_access_grants`, `oauth_applications` (`secret`) | `DELETE` tokens/grants; blank app `secret` |
| Feature flags | `flipper_features`, `flipper_gates` | reset (REVIEW) |
| Settings | `settings`/`rails_settings` (rails-settings-cached; YAML/JSON in `value`) | deep-scan + blank |
| PII / login | `users` (Devise: `encrypted_password`, `reset_password_token`, `confirmation_token`, `unlock_token`) | scrub; null the `*_token` columns; password is bcrypt |
| Note | most third-party secrets live in `config/credentials.yml.enc` + `RAILS_MASTER_KEY`, **not the DB** | — |

## Laravel  (fingerprint: `migrations` + `password_reset_tokens`/`failed_jobs`)

| Concern | Tables | Action |
|---|---|---|
| Queues | `jobs`, `job_batches`, `failed_jobs` | `TRUNCATE` |
| Scheduler | `schedule_monitor*` (spatie) | clear |
| Sanctum tokens | `personal_access_tokens` | `DELETE` |
| Passport (OAuth) | `oauth_access_tokens`, `oauth_refresh_tokens`, `oauth_clients` (`secret`) | `DELETE` tokens; blank client `secret` |
| Password resets | `password_reset_tokens` | `TRUNCATE` |
| Sessions | `sessions` | `TRUNCATE` |
| Debug data | `telescope_entries`/`_tags` | `TRUNCATE` (**captures request secrets + PII**) |
| Feature flags | `features` (Pennant) | reset (REVIEW) |
| PII / login | `users` (`password` bcrypt/argon2, `remember_token`, `two_factor_secret`) | scrub; null tokens; password via `Hash::make` |
| Note | provider secrets live in `.env`, not DB | — |

## Node / JavaScript

| Stack | Tables | Action |
|---|---|---|
| Auth.js / NextAuth (Prisma/Drizzle adapter) | `accounts` (**`access_token`,`refresh_token`,`id_token`,`oauth_token_secret`**), `sessions`, `verification_token`, `users` | `DELETE accounts; TRUNCATE sessions, verification_token`; scrub `users` |
| pg-boss | `pgboss.job`, `pgboss.schedule`, `pgboss.archive` | `DELETE FROM pgboss.job`; `DELETE FROM pgboss.schedule` |
| graphile-worker | `graphile_worker.jobs` (or `_private_jobs` in newer versions), `graphile_worker.known_crontabs` (Cron) | delete jobs; clear `known_crontabs` |
| BullMQ | (usually Redis, not DB) | n/a — note it |
| migrations only | `_prisma_migrations`, `knex_migrations`, `typeorm_metadata` | identifies ORM; secrets are in app config tables → deep-scan |

## Spring / JVM  (fingerprint: `flyway_schema_history` or `databasechangelog`)

| Concern | Tables | Action |
|---|---|---|
| Quartz scheduler | `qrtz_triggers`, `qrtz_job_details`, `qrtz_cron_triggers`, `qrtz_simple_triggers` | pause: `UPDATE qrtz_triggers SET trigger_state='PAUSED'`; or delete cron/simple triggers |
| Spring Session | `spring_session`, `spring_session_attributes` | `TRUNCATE` |
| ShedLock | `shedlock` | `TRUNCATE` |
| Config | app-specific tables | deep-scan; most secrets in `application.yml`/Vault, not DB |

## WordPress  (MySQL; fingerprint: `wp_options`, `wp_users`)

| Concern | Table | Action |
|---|---|---|
| Config + secrets | `wp_options` (`option_name` in `siteurl`,`home`,`*_api_key`,`*_secret`,`mailgun`,`smtp_pass`,`woocommerce_*`) | repoint `siteurl`/`home`; blank secret options |
| WP-Cron | `wp_options` row `option_name='cron'` (serialized) | clear/disable, set `DISABLE_WP_CRON` |
| Sessions/transients | `wp_options` `_transient_*`, `wp_usermeta` `session_tokens` | delete |
| PII / login | `wp_users` (`user_email`, `user_pass` phpass), `wp_usermeta` | scrub; reset `user_pass` via WP hasher |
| Note | option values are PHP-serialized — JSON deep-scan won't parse them; handle by `option_name` | — |

## Magento / Adobe Commerce  (MySQL; fingerprint: `core_config_data`, `setup_module`)

Secrets live in a **key/value config table**, not JSON — run `kv-scan-mysql.sql`.

| Concern | Tables | Action |
|---|---|---|
| Config + secrets | `core_config_data` (`path`/`value`; carrier passwords, payment `pwd`, `*/api_key`, `*/secret`, AWS keys, SMTP) | kv-scan to find paths; repoint base URLs (`web/unsecure/base_url`, `web/secure/base_url`), blank/rotate secret paths. Some values are encrypted with the instance crypt key — still rotate. |
| Cron | `cron_schedule` (pending/running jobs) | `DELETE FROM cron_schedule` (or set `status='error'`); Magento cron is also driven externally — disable the OS cron on the stage box |
| API / OAuth | `oauth_token`, `oauth_consumer` (`secret`), `api_user` (`api_key`), `integration` | `DELETE` tokens; blank consumer/integration secrets |
| Sessions | `session` / `core_session` (if DB-backed) | `TRUNCATE` |
| PII / login | `admin_user` (`password` bcrypt, `rp_token`), `customer_entity` (`password_hash`, `email`) | scrub email; null `rp_token`; password is bcrypt — set a known hash or use `bin/magento admin:user:create` |

Other MySQL commerce stacks follow the same key/value shape: **PrestaShop** `ps_configuration` (`name`/`value`), **OpenCart** `oc_setting` (`key`/`value`), **WooCommerce** rides WordPress `wp_options` (config) + `woocommerce_api_keys` (REST keys; HPOS orders in `wc_orders`, legacy orders in `wp_posts`/`woocommerce_order_items`). Add the relevant (table, key, value) triple to `kv-scan-mysql.sql`'s registry.

> **Prefix caveat.** WordPress/WooCommerce (`wp_`), PrestaShop (`ps_`), and OpenCart (`oc_`)
> table prefixes are set at install. The fingerprint assumes defaults — for a custom prefix,
> read the table list and adjust the signatures + kv-scan registry by hand.

## Supabase / GoTrue  (Postgres `auth` schema)

| Concern | Table | Action |
|---|---|---|
| Refresh tokens | `auth.refresh_tokens` | `TRUNCATE` |
| Sessions | `auth.sessions` | `TRUNCATE` |
| Identities (OAuth) | `auth.identities` (`identity_data` JSON) | scrub provider tokens |
| Users / PII | `auth.users` (`encrypted_password`, `email`, `phone`, raw_*_meta_data JSON) | scrub; password is bcrypt |
