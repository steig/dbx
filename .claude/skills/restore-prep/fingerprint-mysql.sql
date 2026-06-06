-- restore-prep :: framework fingerprint (MySQL 8+)
-- MySQL port of fingerprint.sql. Scoped to the CURRENT database (DATABASE()), so
-- connect to the clone: docker exec -i mysql-dbx mysql -u root -p<pw> <clone> < fingerprint-mysql.sql
-- For every framework reported PRESENT, apply that section of frameworks.md.
-- Read-only. (Postgres-only frameworks — pg-boss, graphile-worker, Supabase/GoTrue —
-- are omitted; they don't run on MySQL.)
--
-- TABLE PREFIXES: WordPress (wp_), PrestaShop (ps_), OpenCart (oc_) all allow a
-- custom prefix at install. These signatures assume the default; if a store uses a
-- custom prefix, detection misses it — check the table list manually and adjust.

SELECT s.framework, s.kind, s.tbl,
       IF(t.table_name IS NULL, '-', 'PRESENT') AS present
FROM (
            SELECT 'Django' framework,'core' kind,'django_migrations' tbl
  UNION ALL SELECT 'Django','jobs','django_celery_beat_periodictask'
  UNION ALL SELECT 'Django','jobs','django_celery_results_taskresult'
  UNION ALL SELECT 'Django','jobs','scheduler_cronjob'
  UNION ALL SELECT 'Django','secrets','authtoken_token'
  UNION ALL SELECT 'Django','secrets','social_auth_usersocialauth'
  UNION ALL SELECT 'Django','secrets','socialaccount_socialtoken'
  UNION ALL SELECT 'Django','config','constance_config'
  UNION ALL SELECT 'Django','flags','waffle_flag'
  UNION ALL SELECT 'Django','config','django_site'
  UNION ALL SELECT 'Rails','core','ar_internal_metadata'
  UNION ALL SELECT 'Rails','core','schema_migrations'
  UNION ALL SELECT 'Rails','jobs','good_jobs'
  UNION ALL SELECT 'Rails','jobs','delayed_jobs'
  UNION ALL SELECT 'Rails','jobs','solid_queue_jobs'
  UNION ALL SELECT 'Rails','secrets','oauth_access_tokens'
  UNION ALL SELECT 'Rails','flags','flipper_features'
  UNION ALL SELECT 'Rails','storage','active_storage_blobs'
  UNION ALL SELECT 'Laravel','core','migrations'
  UNION ALL SELECT 'Laravel','jobs','failed_jobs'
  UNION ALL SELECT 'Laravel','jobs','jobs'
  UNION ALL SELECT 'Laravel','jobs','job_batches'
  UNION ALL SELECT 'Laravel','secrets','personal_access_tokens'
  UNION ALL SELECT 'Laravel','secrets','oauth_clients'
  UNION ALL SELECT 'Laravel','config','telescope_entries'
  UNION ALL SELECT 'Laravel','flags','features'
  UNION ALL SELECT 'Laravel','auth','password_reset_tokens'
  UNION ALL SELECT 'Magento','core','core_config_data'
  UNION ALL SELECT 'Magento','core','setup_module'
  UNION ALL SELECT 'Magento','jobs','cron_schedule'
  UNION ALL SELECT 'Magento','secrets','oauth_token'
  UNION ALL SELECT 'Magento','secrets','oauth_consumer'
  UNION ALL SELECT 'Magento','secrets','api_user'
  UNION ALL SELECT 'Magento','pii','customer_entity'
  UNION ALL SELECT 'WooCommerce','core','wc_orders'             -- HPOS stores
  UNION ALL SELECT 'WooCommerce','core','woocommerce_order_items' -- legacy (wp_posts-based)
  UNION ALL SELECT 'WooCommerce','secrets','woocommerce_api_keys'
  UNION ALL SELECT 'PrestaShop','core','ps_configuration'
  UNION ALL SELECT 'OpenCart','config','oc_setting'
  UNION ALL SELECT 'WordPress','config','wp_options'
  UNION ALL SELECT 'WordPress','pii','wp_users'
  UNION ALL SELECT 'WordPress','pii','wp_usermeta'
  UNION ALL SELECT 'Node/ORM','core','knex_migrations'
  UNION ALL SELECT 'Node/ORM','core','typeorm_metadata'
  UNION ALL SELECT 'Spring/Quartz','jobs','qrtz_triggers'
  UNION ALL SELECT 'Flyway','core','flyway_schema_history'
  UNION ALL SELECT 'Liquibase','core','databasechangelog'
) s
LEFT JOIN information_schema.tables t
  ON t.table_schema = DATABASE() AND t.table_name = s.tbl
ORDER BY (t.table_name IS NULL), s.framework, s.kind, s.tbl;
