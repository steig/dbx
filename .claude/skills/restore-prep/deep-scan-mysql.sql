-- restore-prep :: deep JSON secret scan (MySQL 8+)
-- MySQL port of deep-scan.sql. Same contract: walk EVERY json column in the
-- current database, classify leaf strings by value-pattern + key-name, emit
-- VALUE-FREE (table, column, path_template, category, hits). Path templates
-- collapse email/hash/token-shaped segments so data-as-keys can't leak.
--
-- MySQL has no jsonb_each and its recursive CTEs don't take a lateral JSON
-- expansion, so this walks the tree iteratively with a worklist (one level per
-- loop) inside a stored procedure. Sampling: at most @sample rows per column
-- (default 500); coverage is reported.
--
-- Run (default sample):
--   docker exec -i mysql-dbx mysql -u root -p<pw> <clone> < deep-scan-mysql.sql
-- Override sample:
--   docker exec -i mysql-dbx mysql -u root -p<pw> <clone> \
--     --init-command="SET @sample=200" < deep-scan-mysql.sql
-- Read-only against data; creates only TEMPORARY tables + a transient procedure.

SET @sample = COALESCE(@sample, 500);
SET SESSION group_concat_max_len = 4000000;

DROP TEMPORARY TABLE IF EXISTS _rp_seed;
CREATE TEMPORARY TABLE _rp_seed(tn VARCHAR(128), cn VARCHAR(128), path VARCHAR(2000), node JSON);
DROP TEMPORARY TABLE IF EXISTS _rp_findings;
CREATE TEMPORARY TABLE _rp_findings(table_name VARCHAR(128), column_name VARCHAR(128),
  path_template VARCHAR(2000), category VARCHAR(40), hits BIGINT);
DROP TEMPORARY TABLE IF EXISTS _rp_coverage;
CREATE TEMPORARY TABLE _rp_coverage(table_name VARCHAR(128), column_name VARCHAR(128),
  total_rows BIGINT, scanned_rows BIGINT);

-- 1. Dynamically seed roots of every json column (one statement, UNION ALL). No
--    regex here, so no double-escaping — the regex lives in the static procedure.
SELECT CONCAT('INSERT INTO _rp_seed ', GROUP_CONCAT(
         CONCAT('(SELECT ', QUOTE(table_name), ',', QUOTE(column_name),
                ', CAST(''$'' AS CHAR(2000)), CAST(`', column_name, '` AS JSON)',
                ' FROM `', table_name, '` WHERE `', column_name, '` IS NOT NULL LIMIT ', @sample, ')')
         SEPARATOR ' UNION ALL '))
INTO @seed
FROM information_schema.columns
WHERE table_schema = DATABASE() AND data_type = 'json'
  AND EXISTS (SELECT 1 FROM information_schema.tables t
              WHERE t.table_schema = DATABASE()
                AND t.table_name = information_schema.columns.table_name
                AND t.table_type = 'BASE TABLE');

SELECT CONCAT('INSERT INTO _rp_coverage ', GROUP_CONCAT(
         CONCAT('SELECT ', QUOTE(table_name), ',', QUOTE(column_name),
                ', COUNT(*), LEAST(COUNT(*), ', @sample, ')',
                ' FROM `', table_name, '` WHERE `', column_name, '` IS NOT NULL')
         SEPARATOR ' UNION ALL '))
INTO @cov
FROM information_schema.columns
WHERE table_schema = DATABASE() AND data_type = 'json'
  AND EXISTS (SELECT 1 FROM information_schema.tables t
              WHERE t.table_schema = DATABASE()
                AND t.table_name = information_schema.columns.table_name
                AND t.table_type = 'BASE TABLE');

-- No json columns at all → @seed is NULL; guard so the rest is a clean no-op.
SET @seed = COALESCE(@seed, 'DO 0');
SET @cov  = COALESCE(@cov,  'DO 0');
PREPARE s1 FROM @seed; EXECUTE s1; DEALLOCATE PREPARE s1;
PREPARE s2 FROM @cov;  EXECUTE s2; DEALLOCATE PREPARE s2;

DELIMITER $$
DROP PROCEDURE IF EXISTS rp_deep_scan $$
CREATE PROCEDURE rp_deep_scan()
BEGIN
  DECLARE lvl INT DEFAULT 0;   -- depth guard: config/data JSON is never this deep
  DROP TEMPORARY TABLE IF EXISTS _rp_work;
  CREATE TEMPORARY TABLE _rp_work(tn VARCHAR(128), cn VARCHAR(128), path VARCHAR(2000), node JSON);
  INSERT INTO _rp_work SELECT tn,cn,path,node FROM _rp_seed;
  DROP TEMPORARY TABLE IF EXISTS _rp_leaves;
  CREATE TEMPORARY TABLE _rp_leaves(tn VARCHAR(128), cn VARCHAR(128), path VARCHAR(2000), v LONGTEXT);

  WHILE (SELECT COUNT(*) FROM _rp_work) > 0 AND lvl < 64 DO
    SET lvl = lvl + 1;
    -- harvest string leaves at this level
    INSERT INTO _rp_leaves
      SELECT tn,cn,path, JSON_UNQUOTE(node)
      FROM _rp_work
      WHERE JSON_TYPE(node)='STRING' AND CHAR_LENGTH(JSON_UNQUOTE(node))>0;

    -- expand one level into a fresh worklist
    DROP TEMPORARY TABLE IF EXISTS _rp_next;
    CREATE TEMPORARY TABLE _rp_next(tn VARCHAR(128), cn VARCHAR(128), path VARCHAR(2000), node JSON);
    -- object children (key by name)
    INSERT INTO _rp_next
      SELECT w.tn, w.cn,
             CAST(CONCAT(w.path,'.',jt.k) AS CHAR(2000)),
             JSON_EXTRACT(w.node, CONCAT('$."', REPLACE(REPLACE(jt.k,'\\','\\\\'),'"','\\"'), '"'))
      FROM _rp_work w,
           JSON_TABLE(JSON_KEYS(w.node), '$[*]' COLUMNS (k VARCHAR(512) PATH '$')) jt
      WHERE JSON_TYPE(w.node)='OBJECT';
    -- array children (collapse index to [])
    INSERT INTO _rp_next
      SELECT w.tn, w.cn,
             CAST(CONCAT(w.path,'[]') AS CHAR(2000)),
             jt.v
      FROM _rp_work w,
           JSON_TABLE(w.node, '$[*]' COLUMNS (v JSON PATH '$')) jt
      WHERE JSON_TYPE(w.node)='ARRAY';

    DELETE FROM _rp_work;
    INSERT INTO _rp_work SELECT * FROM _rp_next;
  END WHILE;

  -- classify (single CASE; group on the computed columns)
  INSERT INTO _rp_findings(table_name,column_name,path_template,category,hits)
  SELECT tn, cn, tmpl, category, COUNT(*)
  FROM (
    SELECT tn, cn,
      -- value-free path: collapse data-as-key shapes (email/uuid/ssn/hash/token/number)
      REGEXP_REPLACE(
      REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(REGEXP_REPLACE(
        path,
        '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}',                             '<email>'),
        '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<uuid>'),
        '[0-9]{3}-[0-9]{2}-[0-9]{4}',                                                  '<num>'),
        '[0-9a-f]{16,}',                                                               '<hash>'),
        '[A-Za-z0-9]{20,}',                                                            '<token>'),
        '[0-9]{6,}',                                                                   '<num>'),
        '^\\$\\.?', '') AS tmpl,
      CASE
        WHEN REGEXP_LIKE(v,'BEGIN[A-Z ]*PRIVATE KEY','c') OR REGEXP_LIKE(v,'BEGIN RSA','c') THEN 'private_key'
        WHEN REGEXP_LIKE(v,'^AKIA[0-9A-Z]{16}$','c')                THEN 'aws_access_key_id'
        WHEN REGEXP_LIKE(v,'^(sk|pk|rk)_(live|test)_','c')          THEN 'stripe_key'
        WHEN REGEXP_LIKE(v,'^xox[bpoas]-','c')                      THEN 'slack_token'
        WHEN REGEXP_LIKE(v,'^AIza[0-9A-Za-z_-]{35}$','c')           THEN 'google_api_key'
        WHEN REGEXP_LIKE(v,'^gh[pousr]_[A-Za-z0-9]{20,}','c')       THEN 'github_token'
        WHEN REGEXP_LIKE(v,'^shp(at|ca|pa|ss)_[a-f0-9]{32}$','c')   THEN 'shopify_token'
        WHEN REGEXP_LIKE(v,'^eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.','c') THEN 'jwt'
        WHEN REGEXP_LIKE(v,'://[^/@:]+:[^/@]+@','c')                THEN 'url_with_inline_credentials'
        WHEN REGEXP_LIKE(v,'^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$','i') THEN 'email'
        WHEN REGEXP_LIKE(leaf,'^(.*_)?(api_?key|api_?token|access_token|refresh_token|client_secret|secret|secret_key|auth_key|password|passwd|private_key)$','c')
             AND NOT REGEXP_LIKE(leaf,'^(last_|.*_at|.*expires.*)$','c') THEN 'secret_by_keyname'
        WHEN CHAR_LENGTH(v)>=32 AND REGEXP_LIKE(v,'^[A-Za-z0-9_/+=-]+$','c') THEN 'high_entropy_token_like'
        ELSE 'other'
      END AS category
    FROM (
      SELECT tn, cn, path,
             LOWER(REGEXP_SUBSTR(REGEXP_REPLACE(path,'(\\[\\])+$',''),'[^.]+$')) AS leaf, v
      FROM _rp_leaves
    ) z
  ) c
  GROUP BY tn, cn, tmpl, category;
END $$
DELIMITER ;

CALL rp_deep_scan();
DROP PROCEDURE IF EXISTS rp_deep_scan;

-- == output ==
SELECT '== sensitive leaves by category (value-free) ==' AS '';
SELECT category, SUM(hits) AS hits, COUNT(*) AS distinct_paths
FROM _rp_findings WHERE category <> 'other'
GROUP BY category ORDER BY (category='high_entropy_token_like'), hits DESC;

SELECT '== where they live (declare as scrub paths / strip in hook; high_entropy omitted) ==' AS '';
SELECT table_name, column_name, path_template, category, hits
FROM _rp_findings
WHERE category IN ('private_key','aws_access_key_id','stripe_key','slack_token',
  'google_api_key','github_token','shopify_token','jwt','url_with_inline_credentials',
  'secret_by_keyname','email')
ORDER BY FIELD(category,'private_key','aws_access_key_id','stripe_key','slack_token',
  'google_api_key','github_token','shopify_token','jwt','url_with_inline_credentials',
  'secret_by_keyname','email'), table_name, path_template;

SELECT '== coverage (scanned/total; raise @sample if a big table may hide rare secrets) ==' AS '';
SELECT table_name, column_name, scanned_rows, total_rows
FROM _rp_coverage WHERE scanned_rows < total_rows ORDER BY total_rows DESC;
