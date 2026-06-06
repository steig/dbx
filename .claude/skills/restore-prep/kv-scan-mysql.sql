-- restore-prep :: key/value config scan (MySQL 8+)
-- Many frameworks keep secrets in a KEY/VALUE config table, not JSON — Magento
-- `core_config_data` (path/value), WordPress `wp_options` (option_name/value),
-- Django `constance_config` (key/value). deep-scan only walks JSON, so this
-- complements it: classify each config ROW by key-name and value-pattern.
-- VALUE-FREE output: (config_table, key_template, category, hits). Numeric runs in
-- keys collapse to <n> so per-scope/per-store rows group.
--
-- Run against the clone's current database:
--   docker exec -i mysql-dbx mysql -u root -p<pw> <clone> < kv-scan-mysql.sql
-- Read-only; TEMP tables only. Add a row to the registry below for any other
-- key/value config table you find — but only tables whose KEY column holds
-- descriptive config paths, not user data (key_template is emitted, so a key
-- column containing PII/values would leak; deep-scan handles data-bearing JSON).
--
-- COVERAGE CAVEAT: values are matched as raw text. Secrets inside PHP-serialized
-- blobs (WordPress `wp_options`) or values encrypted with the app's crypt key
-- (Magento `core_config_data`) are NOT decoded — anchored patterns won't see them.
-- A 'clean' result for such a column means "no plaintext secret found", not "no
-- secret". Encrypted values usually surface as `high_entropy_value`; treat the
-- key path (e.g. `payment/.../secret`) as the real signal, not the value.

SET SESSION group_concat_max_len = 4000000;

DROP TEMPORARY TABLE IF EXISTS _rp_kv_seed;
CREATE TEMPORARY TABLE _rp_kv_seed(src VARCHAR(128), k LONGTEXT, v LONGTEXT);
DROP TEMPORARY TABLE IF EXISTS _rp_kv;
CREATE TEMPORARY TABLE _rp_kv(config_table VARCHAR(128), key_template VARCHAR(512),
  category VARCHAR(40), hits BIGINT);

-- Registry of known key/value config tables (table, key column, value column),
-- filtered to those actually present. No regex here → no escaping concerns.
-- Exclude WordPress transients (cache, not config — high volume + noise) and cap
-- each table at 200k rows so a pathologically large options table can't blow up.
SELECT CONCAT('INSERT INTO _rp_kv_seed ', GROUP_CONCAT(
         CONCAT('(SELECT ', QUOTE(reg.tbl), ', `', reg.kcol, '`, `', reg.vcol,
                '` FROM `', reg.tbl,
                '` WHERE `', reg.kcol, '` NOT LIKE ''\\_transient\\_%''',
                ' AND `', reg.kcol, '` NOT LIKE ''\\_site\\_transient\\_%''',
                ' LIMIT 200000)')
         SEPARATOR ' UNION ALL '))
INTO @kv
FROM (
            SELECT 'core_config_data' tbl, 'path'        kcol, 'value'        vcol
  UNION ALL SELECT 'wp_options',           'option_name',       'option_value'
  UNION ALL SELECT 'constance_config',     'key',               'value'
) reg
JOIN information_schema.tables t
  ON t.table_schema = DATABASE() AND t.table_name = reg.tbl;

SET @kv = COALESCE(@kv, 'DO 0');
PREPARE k1 FROM @kv; EXECUTE k1; DEALLOCATE PREPARE k1;

-- Static classify (regex lives here → single-level escaping).
INSERT INTO _rp_kv(config_table, key_template, category, hits)
SELECT src, key_template, category, COUNT(*)
FROM (
  SELECT src,
    REGEXP_REPLACE(k, '[0-9]+', '<n>') AS key_template,
    CASE
      WHEN REGEXP_LIKE(v,'BEGIN[A-Z ]*PRIVATE KEY','c')           THEN 'private_key'
      WHEN REGEXP_LIKE(v,'^(sk|pk|rk)_(live|test)_','c')          THEN 'stripe_key'
      WHEN REGEXP_LIKE(v,'^xox[bpoas]-','c')                      THEN 'slack_token'
      WHEN REGEXP_LIKE(v,'^AIza[0-9A-Za-z_-]{35}$','c')           THEN 'google_api_key'
      WHEN REGEXP_LIKE(v,'^eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.','c') THEN 'jwt'
      WHEN REGEXP_LIKE(v,'://[^/@:]+:[^/@]+@','c')                THEN 'url_with_inline_credentials'
      WHEN REGEXP_LIKE(v,'^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$','i') THEN 'email'
      -- key-name signal, with the common config-noise excluded
      WHEN REGEXP_LIKE(k,'(secret|api_?key|apikey|client_secret|private_key|access_key|bearer_token|slack_token|/password$|/token$|/pass$|/pwd$)','i')
           AND NOT REGEXP_LIKE(k,'(template|expiration|_times|_identity|flow_secure|reset_link|require_|_country|_vat|enable|_period)','i')
                                                                   THEN 'secret_by_key'
      WHEN CHAR_LENGTH(v)>=32 AND REGEXP_LIKE(v,'^[A-Za-z0-9_/+=-]+$','c') THEN 'high_entropy_value'
      ELSE 'other'
    END AS category
  FROM _rp_kv_seed
) z
GROUP BY src, key_template, category;

SELECT '== key/value config secrets by category (value-free) ==' AS '';
SELECT config_table, category, SUM(hits) hits, COUNT(*) distinct_keys
FROM _rp_kv WHERE category <> 'other'
GROUP BY config_table, category
ORDER BY (category='high_entropy_value'), hits DESC;

SELECT '== secret key paths (templates only, no values; high_entropy omitted) ==' AS '';
SELECT config_table, key_template, category, hits
FROM _rp_kv
WHERE category IN ('private_key','stripe_key','slack_token','google_api_key','jwt',
  'url_with_inline_credentials','secret_by_key','email')
ORDER BY config_table, FIELD(category,'private_key','stripe_key','slack_token',
  'google_api_key','jwt','url_with_inline_credentials','secret_by_key','email'), key_template;

SELECT CONCAT('note: values matched as raw text — secrets inside serialized/encrypted values ',
              'are not decoded. Trust the key path; rotate high_entropy_value rows too.') AS '';
