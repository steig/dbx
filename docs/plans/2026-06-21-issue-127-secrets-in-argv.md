# Keep secrets out of process argv

**Issue:** #127  
**Status:** Plan (revised, finalize completed). ~30 call sites across 4 files.  
**Generated:** 2026-06-21 via multi-agent investigate→verify→synthesize workflow.

## Root cause

Secrets are passed as command arguments / inline env-prefixes, making them visible in argv to any user on the host via `ps`/`/proc/PID/cmdline`. Two vuln classes, both confirmed at current HEAD (1c4f876): (1) GPG passphrase passed via `--passphrase \"$passphrase\"` at lib/core.sh:450, 673, 682 (encrypt_stream/decrypt_stream and the vault GPG write). (2) DB passwords passed via `docker exec -e PGPASSWORD=\"$var\"` / `-e MYSQL_PWD=\"$var\"` and host-side `PGPASSWORD=cmd` / `env PGPASSWORD=` prefixes across postgres.sh, mysql.sh, core.sh, and scrub.sh. The codebase already proves the safe pattern for one path: create_mysql_credential_file (lib/core.sh:991) writes a chmod-600 `--defaults-extra-file`; the rest of the call sites were never converted. NOTE the draft cited stale line numbers from the 2026-06-18 audit (core.sh:666/675/443 for gpg, core.sh:1392/1404 for docker) — those are WRONG: core.sh:1392/1404 are now Postgres image-resolution logic with no secrets, and the real gpg sites are 450/673/682. The critique is correct on every count; this plan uses re-derived HEAD line numbers.

## Proposed fix

Eliminate secrets from argv at every real-credential site; leave the well-known devpassword defaults alone (documented). Three techniques:

1) GPG (core.sh:450,673,682): replace `--passphrase \"$passphrase\"` with passphrase via stdin/fd using `--pinentry-mode loopback --passphrase-fd 3` and a `3<<<\"$passphrase\"` here-string (or printf into an fd). For the symmetric-encrypt sites that already pipe data on stdin, use a dedicated fd (3) so stdin stays the plaintext stream. Gate behind a capability check in require_gpg (core.sh:663): verify `gpg --version` is 2.1+ AND `gpg --pinentry-mode loopback --version` succeeds; `die` with a clear message if unsupported (no silent fallback — inline --passphrase is the bug we're removing).

2) Docker exec sites: introduce one small helper (in core.sh, mirroring create_mysql_credential_file's role) that runs `docker exec` with a name-only `-e PGPASSWORD` / `-e MYSQL_PWD` inside a subshell that exports the credential into a narrowly-scoped env and exits immediately after, e.g. a helper `docker_exec_with_pg_password <password> <docker-exec-args...>` implemented as `( export PGPASSWORD=\"$1\"; shift; docker exec -e PGPASSWORD \"$@\" )` (and a MYSQL_PWD twin). Subshell scoping means the value never enters argv and is gone on subshell exit, which ALSO sidesteps the cleanup-trap var-name mismatch. Convert each real-credential docker site to call the helper. For the two array-build sites (postgres.sh:869, mysql.sh:708) the name-only `-e PGPASSWORD`/`-e MYSQL_PWD` form goes in the array and the export wraps the final array invocation in a subshell.

3) Host-side psql/pg_restore (postgres.sh:565,569,574): use the same subshell-export pattern (`( export PGPASSWORD=\"$pg_pass\"; psql ... )`) OR a PGPASSFILE tempfile (chmod 600, RETURN-trap cleanup) — inline `PGPASSWORD=cmd` and `env PGPASSWORD=` are equally argv-visible.

Devpassword-default sites (core.sh:206,1598,1628,1634; postgres.sh:71) are NOT real secrets — skip them; add a one-line code comment documenting that they're intentionally left inline.

## Affected locations

- lib/core.sh:450
- lib/core.sh:673
- lib/core.sh:682 (gpg passphrase)
- lib/core.sh:1437
- lib/core.sh:1449
- lib/core.sh:1661
- lib/core.sh:1667 (docker exec real creds)
- lib/core.sh:1017 (cleanup_secrets trap — must harmonize var names)
- lib/core.sh:991 (create_mysql_credential_file — existing precedent to mirror)
- lib/core.sh:663 (require_gpg — add loopback capability gate)
- lib/postgres.sh:71,220,228,278,294,752,790,850,853,869,897,914,952,1055 (docker exec)
- lib/postgres.sh:565,569,574 (HOST-side env PGPASSWORD/PGPASSWORD= prefix — argv-visible; pg_pass is DEV_PG_PASSWORD-overridable so can carry a real secret in remote mode)
- lib/mysql.sh:344,619,642,648,655,960 (docker exec) and 708 (array-append -e MYSQL_PWD=$root_pass)
- lib/scrub.sh:659,697,1123,1147,1187,1204,1399 (docker exec — carry get_password output / container-read root passwords)

## Steps

- Re-confirm the call-site inventory against HEAD (done in this pass) — do NOT trust the stale audit line numbers in the issue/draft.
- Add a GPG loopback/version capability check to require_gpg (core.sh:663); die clearly if GnuPG < 2.1 or loopback unsupported.
- Convert the 3 gpg sites (core.sh:450,673,682) to --pinentry-mode loopback --passphrase-fd, feeding passphrase via fd 3 (not stdin, which carries the data stream).
- Add docker_exec_with_pg_password / docker_exec_with_mysql_pwd subshell-export helpers in core.sh next to create_mysql_credential_file.
- Convert all real-credential docker-exec sites to the helper: postgres.sh (71 excluded as devpw; 220,228,278,294,752,790,850,853,897,914,952,1055), the array sites postgres.sh:869 & mysql.sh:708, mysql.sh:344,619,642,648,655,960, core.sh:1437,1449,1661,1667, and scrub.sh:659,697,1123,1147,1187,1204,1399.
- Convert host-side postgres.sh:565,569,574 to subshell-export (or PGPASSFILE tempfile with chmod 600 + RETURN-trap cleanup).
- Harmonize/retire cleanup_secrets (core.sh:1017): since the subshell approach keeps vars out of the long-lived env, confirm no new exported variant names (target_pass/root_pass/pg_pass/pg_root_pass/my_root_pass/password) escape the subshell; if any export must persist, add it to the unset list.
- Add a bats stub harness: drop `docker` and `gpg` shims on PATH that append "$@" to a log file, exercise backup+restore+scrub code paths, then `refute` the known secret string appears in the log; also assert argv does NOT contain PGPASSWORD=<value>/MYSQL_PWD=<value>/--passphrase <value>.
- Run the full bats suite via `nix shell nixpkgs#bats --command bats tests/unit` (macOS bash 3.2 — watch for ${var//} quirks); confirm green.
- Document in code that devpassword-default sites are intentionally left inline.

## Risks

Subshell-export changes evaluation context: any function that relied on a side effect of being in the current shell (variable mutation, set -e propagation, traps) could behave differently — audit each converted site's surrounding logic. Name-only `-e PGPASSWORD` reads from the docker CLIENT env, so a missing export silently yields an EMPTY password (auth failure, not a crash) — the subshell-export helper must set the var before the exec, every time. GPG loopback requires GnuPG 2.1+; without the new require_gpg gate, hosts with 1.x/2.0 would hang on pinentry — the gate is mandatory, not optional. The array-build sites (postgres.sh:869, mysql.sh:708) need the export wrapping the WHOLE array call, easy to wrap the wrong scope. macOS system bash 3.2 differs from nix bash; rely on the macos-latest unit-test CI to catch pattern-substitution quirks. ~24 docker sites + 3 gpg + 3 host sites is a real refactor, not a one-liner — effort is Medium leaning High.

## Test strategy

Cannot assert argv-absence against real docker/gpg in CI (docker may be absent, no multi-user host). Use a PATH stub harness: a bats setup() prepends a temp dir containing executable `docker` and `gpg` shims that do `printf '%s\\0' \"$@\" >> \"$ARGV_LOG\"` (and emulate minimal expected stdout). Run representative backup, restore, and scrub flows with a sentinel secret (e.g. PASS=\"S3CRET-SENTINEL\"), then `refute grep -q S3CRET-SENTINEL \"$ARGV_LOG\"` and specifically refute `PGPASSWORD=S3CRET`, `MYSQL_PWD=S3CRET`, `--passphrase S3CRET`. Add positive tests that the name-only `-e PGPASSWORD` flag and the loopback gpg flags ARE present (so we don't accidentally drop the env entirely). Place in tests/unit/ alongside scrub.bats / core.bats. Add one require_gpg test that a faked low-version gpg triggers die(). Run: `nix shell nixpkgs#bats --command bats tests/unit`.

## Effort

Medium-High (~30 call sites across 4 files plus a new stub-based test harness and a gpg capability gate; mechanical but high-volume and each site needs scope-correct subshell wrapping)

## Open questions

- Minimum supported GnuPG version: gate at 2.1 (loopback) and hard-die below it, or also provide a PGPASSFILE-style fallback for gpg-less/old-gpg hosts? Recommend hard-die — silent fallback reintroduces the leak.
- Subshell-export helper vs PGPASSFILE/.pgpass tempfile for host-side psql (565/569/574): subshell is simpler but tempfile is the more conventional psql idiom — pick one and apply consistently.
- Should the well-known devpassword-default sites (core.sh:206,1598,1628,1634; postgres.sh:71) be converted too for consistency, or left inline with a documenting comment? Recommend leave + document (they are not the exposure).
- Does any restore/scrub transform code path log the full docker/gpg command (e.g. set -x, debug logging) that would re-leak the secret even after argv is clean? Grep for `set -x`/command-echo before closing the issue.
- For postgres.sh:565, pg_pass is DEV_PG_PASSWORD-overridable — confirm with maintainer whether remote mode is ever used with a real (non-dev) password in practice, which sets the priority of the host-side fix.
