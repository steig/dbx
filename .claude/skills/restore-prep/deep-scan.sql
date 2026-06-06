-- restore-prep :: deep JSONB secret scan (PostgreSQL)
-- Walks EVERY json/jsonb column in schema 'public' recursively (objects + arrays)
-- and classifies leaf STRING values by value-pattern and key-name. Output is
-- VALUE-FREE: (table, column, path_template, category, hits) only.
--
-- Path templates are sanitized so DATA-AS-KEYS can't leak: a doc keyed by an
-- email/hash/token (e.g. {"alice@x.com": {...}}) would otherwise put that value
-- in the path. We collapse email-shaped, hex (>=16), and random-looking (>=20
-- no-separator) path segments to <email>/<hash>/<token>. Descriptive keys with
-- underscores (e.g. payment_intent_client_secret) are preserved.
--
-- Sampling: each column is scanned over at most :sample rows (default 500). For
-- small config tables that's all rows; for huge data tables it's a representative
-- sample (first-N by physical order — raise :sample or note the cap if a rare
-- secret could sit in a late row). Coverage is reported so the cap is never silent.
--
-- Run:  docker exec -i postgres-dbx psql -U postgres -d <clone> -v sample=500 < deep-scan.sql
-- Read-only. Creates only TEMP objects. PostgreSQL only (MySQL needs a JSON_TABLE
-- variant — not yet provided; see SKILL.md).

\set ON_ERROR_STOP on
\if :{?sample}
\else
  \set sample 500
\endif
SET rp.sample = :'sample';

DROP TABLE IF EXISTS _rp_findings;
CREATE TEMP TABLE _rp_findings(
  table_name text, column_name text, path_template text, category text, hits bigint);
DROP TABLE IF EXISTS _rp_coverage;
CREATE TEMP TABLE _rp_coverage(
  table_name text, column_name text, total_rows bigint, scanned_rows bigint);

DO $$
DECLARE
  r record;
  n_total bigint;
  n_scan  bigint;
  sample_n int := current_setting('rp.sample')::int;
BEGIN
  FOR r IN
    SELECT c.table_name, c.column_name
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema=c.table_schema AND t.table_name=c.table_name
    WHERE c.table_schema='public' AND c.data_type IN ('json','jsonb')
      AND t.table_type='BASE TABLE'
    ORDER BY c.table_name, c.column_name
  LOOP
    EXECUTE format('SELECT count(*) FROM %I WHERE %I IS NOT NULL', r.table_name, r.column_name)
      INTO n_total;
    n_scan := LEAST(n_total, sample_n);
    INSERT INTO _rp_coverage VALUES (r.table_name, r.column_name, n_total, n_scan);
    IF n_total = 0 THEN CONTINUE; END IF;

    EXECUTE format($q$
      WITH RECURSIVE src AS (
        SELECT (%1$I)::jsonb AS j FROM %2$I WHERE %1$I IS NOT NULL LIMIT %3$s
      ),
      flat(path, val, depth) AS (
        SELECT '$', j, 0 FROM src
        UNION ALL
        SELECT f.path||child.suffix, child.value, f.depth+1
          FROM flat f,
          LATERAL (
            SELECT '.'||e.key AS suffix, e.value AS value
              FROM jsonb_each(f.val) e WHERE jsonb_typeof(f.val)='object'
            UNION ALL
            SELECT '[]', e.value
              FROM jsonb_array_elements(f.val) e WHERE jsonb_typeof(f.val)='array'
          ) child
          WHERE f.depth < 64        -- depth guard (matches MySQL port)
      ),
      leaves AS (
        SELECT
          -- value-free path: collapse any DATA-as-key shape so a doc keyed by an
          -- email/uuid/ssn/hash/token/number can't leak its value into the template.
          regexp_replace(
          regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
            path,
            '[A-Za-z0-9._%%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',                            '<email>', 'g'),
            '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<uuid>',  'g'),
            '[0-9]{3}-[0-9]{2}-[0-9]{4}',                                                  '<num>',   'g'),
            '[0-9a-f]{16,}',                                                               '<hash>',  'g'),
            '[A-Za-z0-9]{20,}',                                                            '<token>', 'g'),
            '[0-9]{6,}',                                                                   '<num>',   'g'),
            '^\$\.?', '') AS tmpl,
          -- leaf for key-name match: drop trailing array markers so api_keys[] matches
          lower(regexp_replace(regexp_replace(path,'(\[\])+$',''),'.*\.','')) AS leaf,
          (val #>> '{}') AS v
        FROM flat
        WHERE jsonb_typeof(val)='string' AND length(val #>> '{}')>0
      ),
      classified AS (
        SELECT tmpl,
          CASE
            WHEN v ~ 'BEGIN[A-Z ]*PRIVATE KEY' OR v ~ 'BEGIN RSA'        THEN 'private_key'
            WHEN v ~ '^AKIA[0-9A-Z]{16}$'                                THEN 'aws_access_key_id'
            WHEN v ~ '^(sk|pk|rk)_(live|test)_'                          THEN 'stripe_key'
            WHEN v ~ '^xox[bpoas]-'                                      THEN 'slack_token'
            WHEN v ~ '^AIza[0-9A-Za-z_-]{35}$'                           THEN 'google_api_key'
            WHEN v ~ '^gh[pousr]_[A-Za-z0-9]{20,}'                       THEN 'github_token'
            WHEN v ~ '^shp(at|ca|pa|ss)_[a-f0-9]{32}$'                   THEN 'shopify_token'
            WHEN v ~ '^eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.'          THEN 'jwt'
            WHEN v ~ '://[^/@:]+:[^/@]+@'                                THEN 'url_with_inline_credentials'
            WHEN v ~* '^[a-z0-9._%%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'         THEN 'email'
            WHEN leaf ~ '^(.*_)?(api_?key|api_?token|access_token|refresh_token|client_secret|secret|secret_key|auth_key|password|passwd|private_key)$'
                 AND leaf !~ '^(last_|.*_at|.*expires.*)$'               THEN 'secret_by_keyname'
            WHEN length(v)>=32 AND v ~ '^[A-Za-z0-9_\-+/=]+$'            THEN 'high_entropy_token_like'
            ELSE 'other'
          END AS category
        FROM leaves
      )
      INSERT INTO _rp_findings
      SELECT %4$L, %1$L, tmpl, category, count(*)
      FROM classified GROUP BY tmpl, category
    $q$, r.column_name, r.table_name, n_scan, r.table_name);
  END LOOP;
END $$;

\echo '== sensitive leaves by category (value-free) =='
SELECT category, sum(hits) hits, count(*) distinct_paths
FROM _rp_findings
WHERE category <> 'other'
GROUP BY category ORDER BY (category='high_entropy_token_like'), hits DESC;

\echo ''
\echo '== where they live (declare these as scrub paths / strip in hook) =='
\echo '   (high_entropy_token_like omitted here — high noise; check its count above)'
SELECT table_name, column_name, path_template, category, hits
FROM _rp_findings
WHERE category IN ('private_key','aws_access_key_id','stripe_key','slack_token',
  'google_api_key','github_token','shopify_token','jwt','url_with_inline_credentials',
  'secret_by_keyname','email')
ORDER BY array_position(ARRAY['private_key','aws_access_key_id','stripe_key','slack_token',
  'google_api_key','github_token','shopify_token','jwt','url_with_inline_credentials',
  'secret_by_keyname','email'], category), table_name, path_template;

\echo ''
\echo '== coverage (scanned/total rows per json column; raise :sample if a big table may hide rare secrets) =='
SELECT table_name, column_name, scanned_rows, total_rows
FROM _rp_coverage WHERE scanned_rows < total_rows
ORDER BY total_rows DESC;
