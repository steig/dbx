-- restore-prep :: framework fingerprint (PostgreSQL)
-- Detects web frameworks + their ecosystem libraries by signature tables, so the
-- skill can apply the right per-framework playbook (see frameworks.md) instead of
-- relying only on generic regex. A schema can match several (hybrid apps) — that's
-- fine, apply every PRESENT framework's playbook.
--
-- Run: docker exec -i postgres-dbx psql -U postgres -d <clone> -f - < fingerprint.sql
-- Read-only. Postgres/public schema. (WordPress lives in MySQL with a wp_ prefix —
-- see frameworks.md; this file checks the Postgres-resident frameworks.)

WITH sig(framework, kind, tbl) AS (VALUES
  -- Django + ecosystem
  ('Django','core','django_migrations'),
  ('Django','jobs','django_celery_beat_periodictask'),
  ('Django','jobs','django_celery_results_taskresult'),
  ('Django','jobs','django_q_schedule'),
  ('Django','jobs','scheduler_cronjob'),                 -- django-extensions
  ('Django','secrets','authtoken_token'),               -- DRF
  ('Django','secrets','social_auth_usersocialauth'),    -- python-social-auth
  ('Django','secrets','socialaccount_socialtoken'),     -- allauth
  ('Django','secrets','oauth2_provider_accesstoken'),   -- django-oauth-toolkit
  ('Django','config','constance_config'),
  ('Django','flags','waffle_flag'),
  ('Django','flags','waffle_switch'),
  ('Django','config','django_site'),
  -- Rails + ecosystem
  ('Rails','core','ar_internal_metadata'),
  ('Rails','core','schema_migrations'),
  ('Rails','jobs','good_jobs'),
  ('Rails','jobs','delayed_jobs'),
  ('Rails','jobs','solid_queue_jobs'),
  ('Rails','jobs','que_jobs'),
  ('Rails','secrets','oauth_access_tokens'),             -- Doorkeeper
  ('Rails','flags','flipper_features'),
  ('Rails','storage','active_storage_blobs'),
  -- Laravel + ecosystem
  ('Laravel','core','migrations'),
  ('Laravel','jobs','failed_jobs'),
  ('Laravel','jobs','jobs'),
  ('Laravel','jobs','job_batches'),
  ('Laravel','secrets','personal_access_tokens'),        -- Sanctum
  ('Laravel','secrets','oauth_clients'),                 -- Passport
  ('Laravel','config','telescope_entries'),              -- debug data: PII/secrets
  ('Laravel','flags','features'),                        -- Pennant
  -- Node / JS (Auth.js, pg-boss, graphile-worker, Prisma/Knex/TypeORM)
  ('NextAuth/Auth.js','secrets','accounts'),             -- provider OAuth tokens
  ('NextAuth/Auth.js','secrets','verification_token'),
  ('pg-boss','jobs','pgboss.job'),
  ('graphile-worker','jobs','graphile_worker.jobs'),
  ('Prisma','core','_prisma_migrations'),
  ('Knex','core','knex_migrations'),
  ('TypeORM','core','typeorm_metadata'),
  -- Spring / JVM
  ('Spring/Quartz','jobs','qrtz_triggers'),
  ('Flyway','core','flyway_schema_history'),
  ('Liquibase','core','databasechangelog'),
  ('Spring Session','secrets','spring_session'),
  -- Postgres-native auth (Supabase/GoTrue)
  ('Supabase/GoTrue','secrets','auth.refresh_tokens'),
  ('Supabase/GoTrue','core','auth.users')
)
SELECT framework, kind, tbl,
       CASE WHEN to_regclass(CASE WHEN tbl LIKE '%.%' THEN tbl ELSE 'public.'||tbl END) IS NOT NULL
            THEN 'PRESENT' ELSE '-' END AS present
FROM sig
ORDER BY (to_regclass(CASE WHEN tbl LIKE '%.%' THEN tbl ELSE 'public.'||tbl END) IS NULL),
         framework, kind, tbl;
