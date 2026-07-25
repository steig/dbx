# Fix spoofable/racy SSH tunnel reuse

**Issue:** #128  
**Status:** Plan (reconciled: draft + critique; finalize-merge was interrupted).  
**Generated:** 2026-06-21 via multi-agent investigate→verify→synthesize workflow.

## Root cause

create_ssh_tunnel identifies tunnels purely by pattern-matching argv from a system-wide process listing, with no ownership/authenticity binding. lib/tunnel.sh:53 runs `ps -eo pid,command | grep -E "ssh.*-L.*:${target_host}:${target_port}.*${jump_host}"` across ALL users' processes and no UID filter. When a match is found it trusts that process completely: it parses the local port out of the matched argv text (lib/tunnel.sh:57), adopts the matched PID (lib/tunnel.sh:58), sets TUNNEL_REUSED=true, and routes the database connection at that local port (get_effective_port -> TUNNEL_LOCAL_PORT). Because argv is fully controllable by any local user, an attacker can run a process whose command line matches the regex (e.g. an ssh -L forward of the same local port to an attacker-controlled backend, or any command containing the literal substring) and make dbx 'reuse' a tunnel the attacker controls, redirecting prod DB traffic (credential + data interception). Secondary: lib/tunnel.sh:67 picks the port with predictable $RANDOM, lib/tunnel.sh:68 lsof-checks it, and lib/tunnel.sh:77 only binds it later via ssh — a TOCTOU window. And the tunnel's own PID is discovered the same fragile way (lib/tunnel.sh:85, ps-grep on a bare port substring + tail -1), so the cleanup trap can target the wrong PID.

## Proposed fix

Adopt SSH ControlMaster sockets as the authoritative reuse + teardown mechanism, replacing ps-grep entirely. This is the recommended approach over a state file (rationale in risks).

Design:
1. Add a per-user 0700 control dir, e.g. TUNNEL_CONTROL_DIR="${DBX_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-$DATA_DIR}}/tunnels"; `mkdir -p` then `chmod 700`. XDG_RUNTIME_DIR (already 0700, user-owned, tmpfs) is preferred when set; fall back to $DATA_DIR/tunnels. Refuse to use the dir if a stat shows it is not owned by the current uid or not mode 0700 (defends against a pre-created attacker dir).
2. Derive a deterministic control path per target from the tunnel parameters, NOT from a guessable name: ctl="$TUNNEL_CONTROL_DIR/$(printf '%s' "$jump_host|$target_host|$target_port" | shasum -a 256 | cut -c1-32).sock". The socket living in a uid-owned 0700 dir is what makes reuse authoritative — only this user could have created it.
3. Reuse check: `ssh -O check -S "$ctl" "$jump_host" 2>/dev/null`. If it succeeds, a live dbx-owned master already exists -> reuse. To recover the local port for an existing master, persist it alongside the socket in a sibling file "$ctl.port" written 0600 at creation time (read it back on reuse). This removes all argv parsing.
4. Create path: pick the port (see port-fix below), then start the master: `ssh -fN -M -S "$ctl" -o ControlPersist=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -L "$port:$target_host:$target_port" "$jump_host"`. On success write "$ctl.port". No PID needed for teardown.
5. Teardown: replace kill-by-PID with `ssh -O exit -S "$ctl" "$jump_host" 2>/dev/null` and remove "$ctl.port". Keep TUNNEL_REUSED so a reusing run does NOT tear down a master another run created (mirror current intent) — i.e. only the creator issues `-O exit`.
6. Port TOCTOU: keep ExitOnForwardFailure=yes (already present, lib/tunnel.sh:77) which makes ssh fail loudly rather than silently bind wrong, and wrap port selection in a retry loop that treats an ssh forward-bind failure as "try next port" instead of relying solely on the pre-bind lsof. Optionally bind to 127.0.0.1 explicitly (`-L 127.0.0.1:$port:...`) so the port can't be claimed on another interface. This closes the window because the authoritative signal is ssh's own bind result, not the earlier lsof.

Minimum-viable hardening (if ControlMaster is deferred): scope the reuse grep to the current uid (`ps -u "$(id -u)" -o pid,command` / `ps -o pid,command -U "$EUID"`) AND verify the matched PID actually belongs to this user before adopting it (e.g. `ps -o uid= -p "$pid"` equals `id -u`). This shrinks but does not eliminate the spoof surface (a user can still craft a matching argv in their own process), so it is a stopgap, not the fix.

## Affected locations

- /Users/tom.steig/code/dbx/lib/tunnel.sh:53 (spoofable reuse match, no UID scope)
- /Users/tom.steig/code/dbx/lib/tunnel.sh:57-58 (port + PID taken from untrusted argv)
- /Users/tom.steig/code/dbx/lib/tunnel.sh:59-61 (TUNNEL_REUSED set from spoofable match)
- /Users/tom.steig/code/dbx/lib/tunnel.sh:67-68 (predictable RANDOM port + TOCTOU lsof check)
- /Users/tom.steig/code/dbx/lib/tunnel.sh:77-81 (ssh bind happens after the check)
- /Users/tom.steig/code/dbx/lib/tunnel.sh:85-90 (own-PID discovery via ps-grep, tail -1, wrong-PID risk)
- /Users/tom.steig/code/dbx/lib/tunnel.sh:107-117 (cleanup_tunnel keyed on possibly-wrong PID)
- /Users/tom.steig/code/dbx/lib/scrub.sh:636,671 (callers that invoke create_ssh_tunnel per query and depend on reuse)
- /Users/tom.steig/code/dbx/lib/core.sh:10-11 (DATA_DIR/CONFIG_DIR conventions for a 0700 control dir)

## Steps

- Add TUNNEL_CONTROL_DIR setup near the top of lib/tunnel.sh: prefer ${DBX_RUNTIME_DIR:-${XDG_RUNTIME_DIR}} else $DATA_DIR/tunnels; mkdir -p; chmod 700; and stat-verify the dir is uid-owned and mode 0700, die otherwise.
- Add a helper to compute the per-target control socket path from a sha256 of jump_host|target_host|target_port (use shasum -a 256, available on macOS; fall back to sha256sum on Linux).
- Rewrite the reuse block (replace lib/tunnel.sh:50-62): use `ssh -O check -S "$ctl"` to detect a live dbx master; if alive, read TUNNEL_LOCAL_PORT from "$ctl.port", set TUNNEL_REUSED=true, log, return 0. Delete the ps-grep at line 53 and the argv parsing at 57-58.
- Rewrite the create block (replace lib/tunnel.sh:64-98): retry-loop port selection that treats ssh forward-bind failure as retry; start the master with -M -S "$ctl" -o ControlPersist=no -L 127.0.0.1:$port:$target:$tport; on success write "$ctl.port" (umask 077). Remove the ps-grep/lsof PID discovery at 85-91 and the TUNNEL_PID dependency.
- Rewrite cleanup_tunnel (lib/tunnel.sh:107-117): keep the TUNNEL_REUSED short-circuit; for owned tunnels run `ssh -O exit -S "$ctl"` and rm -f "$ctl.port" instead of kill "$TUNNEL_PID". Make $ctl available to cleanup (module-level global set in create).
- Keep the chained trap line `trap 'cleanup_tunnel; cleanup_secrets' EXIT INT TERM` (lib/tunnel.sh:104) so secret cleanup is preserved.
- Verify callers lib/scrub.sh:636,671 and the postgres/mysql backup paths still get correct get_effective_host/get_effective_port behavior (TUNNEL_LOCAL_PORT still set on both create and reuse).
- Update any tunnel man page / docs and CHANGELOG entry referencing tunnel reuse behavior before release (per release-process memory).

## Risks

ControlMaster recommended over the state file because the on-disk unix socket in a uid-owned 0700 dir is self-authenticating: only the current user could have created a socket there, and `ssh -O check` proves the master is alive and ours in one authoritative call, giving correct reuse AND teardown with no PID/argv trust. A state file solves the spoof (you write your own real PID) but reintroduces a TOCTOU/staleness problem: a recorded PID can be dead and recycled to an unrelated process, so cleanup_tunnel could kill an innocent PID, and you must still re-validate liveness/ownership of the recorded PID — more moving parts than letting ssh own the socket. Implementation risks to watch: (1) XDG_RUNTIME_DIR is often unset on macOS — the $DATA_DIR/tunnels fallback must be reachable from inside the postgres-dbx/mysql-dbx containers' host-gateway routing path only for the port, not the socket (the socket stays host-side, fine). (2) ControlPersist=no + the -fN master means the master exits when its forwarding session ends; verify it persists across the multiple per-query create_ssh_tunnel calls in scrub.sh (it will, because reuse re-checks the live master each call). (3) The 0700/ownership stat check must run BEFORE first use to defeat a pre-created attacker dir. (4) bash 3.2 on macOS — avoid pattern-substitution quirks (per memory) in the path/hash helpers; prefer shasum + cut. (5) Concurrent dbx runs racing to create the same master: second `ssh -O check` will see the first's socket and reuse; a tight race may briefly double-create — acceptable, ExitOnForwardFailure makes the loser fail cleanly. Behavior change: tunnels are now torn down via `ssh -O exit` not SIGTERM; confirm no test asserts on a specific kill.

## Test strategy

bats (the project runner: `nix shell nixpkgs#bats --command bats`). Add unit tests around the new helpers with ssh stubbed (function shadow on PATH): (1) spoof test — a fake all-users process / fake argv matching the old regex must NOT be reused now (assert dbx creates its own master); (2) reuse test — a live `ssh -O check`-returning-0 stub yields TUNNEL_REUSED=true and reads port from the .port file; (3) dir-hardening test — a pre-existing control dir owned by another uid or mode != 0700 causes die; (4) teardown test — cleanup_tunnel on an owned tunnel calls `ssh -O exit` and removes the .port file, and on a reused tunnel does neither; (5) port-retry test — first port bind fails (stub returns ExitOnForwardFailure error) and the loop advances to a second port. Keep the macos-latest unit-test CI lane (it catches bash 3.2 quirks the nix bash hides, per memory). Manual integration: reuse the existing rootless-tunnel spike (docs/plans/2026-05-29-rootless-tunnel-spike.sh) to confirm sibling-container reachability still works with a ControlMaster-held tunnel.

## Effort

Medium. ~1 file of real change (lib/tunnel.sh, ~60 lines rewritten across the reuse/create/cleanup blocks) plus new bats tests and a docs/CHANGELOG touch. No caller API change (globals TUNNEL_LOCAL_PORT/TUNNEL_REUSED preserved), so scrub.sh/postgres.sh/mysql.sh need verification not edits. Most of the effort is test scaffolding (ssh stubbing) and validating ControlMaster persistence across the per-query reuse pattern.

## Open questions

- Is XDG_RUNTIME_DIR reliably available in the dbx serve container image (ghcr.io/steig/dbx) and on the rootless-Docker host, or should we standardize on $DATA_DIR/tunnels everywhere for consistency between mac/Linux/container?
- Does the dbx serve (headless/team) deployment ever run multiple distinct OS users sharing one $HOME/$DATA_DIR? If so the uid scoping is moot and we must rely on the 0700 dir + socket ownership exclusively — confirm the multi-tenant model.
- Should reuse be allowed to adopt a master started by a DIFFERENT dbx process of the SAME user (current intent), or restricted to the same process tree? ControlMaster naturally allows cross-process same-user reuse, which matches the documented goal but means one run's `ssh -O exit` won't fire if another run is still using it — verify that is acceptable (it matches the existing TUNNEL_REUSED skip-kill behavior).
- macOS ships shasum but the serve container is alpine (sha256sum) — confirm the hash helper picks the right binary on each platform.
- Is binding the forward to 127.0.0.1 explicitly compatible with the container host-gateway reachability requirement (get_effective_host returns host.docker.internal)? The spike binds on 0.0.0.0 for sibling-container access — reconcile loopback-bind hardening with the documented 0.0.0.0 routing for dbx serve.

## Reconciliation (draft + adversarial critique)

> The workflow's finalize-merge agent for this issue hit a schema-validation
> retry loop and was stopped; this plan is the completed **investigate draft**
> above, with the **adversarial critique's corrections** applied below.
> Treat the corrections as overriding the draft where they conflict.

**Critique verdict:** needs-revision

### Corrections to apply (override the draft on conflict)

1. Replace the call-site inventory: drop scrub.sh:636,671 as the dependent callers (note they are dead code — consider deleting scrub_schema_query_pg/scrub_schema_query_mysql separately) and add the four live callers dbx:194-195 (backup), dbx:1555-1556 (analyze), dbx:2524-2525 (restore/danger path), dbx:2613-2615 (test). Step 7 should verify get_effective_host/get_effective_port behavior at dbx and at lib/postgres.sh:110-111/926-927, lib/mysql.sh:56-57/727-728, lib/core.sh:1654-1655 — these consume TUNNEL_LOCAL_PORT and must still work on both create and reuse.
2. Define the function's exit-code contract explicitly and make dbx:2615 work: on unrecoverable failure either keep `die` (and then the caller's else branch is moot) OR `return 1` consistently. Pick one and document it; do not leave both die and return paths ambiguous.
3. Resolve the bind contradiction before implementation: do NOT prescribe -L 127.0.0.1 unconditionally. Either keep host-default binding (mac/Docker Desktop reaches via host.docker.internal/host-gateway, which is the documented model in tunnel.sh:120-135) or make the bind address conditional on deployment (loopback for local CLI, 0.0.0.0 for serve/sibling-container). This must be decided, not left as an open question while the step hardcodes loopback.
4. Add an explicit forward-liveness re-check on the reuse path: after `ssh -O check` succeeds and the port is read from $ctl.port, confirm something is actually listening on 127.0.0.1:$port (or that the forward is present) before setting TUNNEL_REUSED=true and routing traffic. Treat a missing forward as 'create fresh', not 'reuse'.
5. Add stale-socket handling to the create path: if `ssh -O check` fails but the socket file exists, `rm -f $ctl` (and $ctl.port) before `ssh -M -S $ctl`, so a crashed prior run does not wedge creation. Verify this rm is itself safe given the 0700 uid-owned dir guarantee.
6. Re-justify ControlMaster persistence against the REAL usage (one create per dbx command), not the dead per-query scrub pattern. If masters do not persist across separate dbx invocations under ControlPersist=no -fN, either set ControlPersist=<timeout> or accept that cross-invocation reuse may not fire (which is fine functionally but contradicts the stated reuse goal).
7. Re-scope effort and tests: account for building ssh-stub bats scaffolding from scratch (no precedent exists) and for the macOS bash 3.2 lane. The hash helper should reuse the existing portable _sha256_stdin in core.sh:1228 (sha256sum-or-shasum) rather than introducing a new shasum-only path — this also resolves openQuestion #4 (alpine sha256sum vs mac shasum) for free.

### Critique-identified gaps

- MISSING CALL SITES (the big one). The plan's affectedLocations and step 7 cite only lib/scrub.sh:636,671 as the callers that depend on reuse. Those two functions (scrub_schema_query_pg / scrub_schema_query_mysql) are DEAD CODE: grep across lib/, dbx, and tests/ shows zero callers — the live scrub path uses the _local variants (scrub.sh:1227-1228, 1446-1447) which never tunnel. Meanwhile the plan completely misses the 4 REAL create_ssh_tunnel callers, all in the dbx entrypoint: dbx:194-195, dbx:1555-1556, dbx:2524-2525, and dbx:2613-2615. The verification in step 7 is therefore pointed at the wrong (inactive) code.
- RETURN-VALUE CONTRACT BREAK at dbx:2615. That caller does `if create_ssh_tunnel "$host"; then ... else log_error 'SSH tunnel failed'; return 1; fi` — it relies on a meaningful nonzero exit. The current function only ever `return 0` or `die`s, so today the else branch is dead, but the plan's rewrite (retry loop, ssh -O check, ssh -O exit) introduces new failure paths. The plan does not specify the function's exit-code contract, so this caller's error handling could silently misbehave or the function could `die` where the caller expected a recoverable `return 1`.
- 127.0.0.1 BIND CONTRADICTS THE SERVE/ROOTLESS DESIGN. Step 4 prescribes `-L 127.0.0.1:$port:...` as hardening, but docs/plans/2026-05-29-rootless-tunnel-spike.sh:108-125 explicitly binds 0.0.0.0 so SIBLING containers on the shared net can reach the tunnel (the dbx serve container's role). The plan lists this as openQuestion #5 yet still prescribes the loopback bind in the concrete step — an internal contradiction that, if implemented as written, breaks sibling-container reachability in the serve deployment.
- TEST STRATEGY OVERSTATES EXISTING SCAFFOLDING. There are NO existing tunnel unit tests and NO ssh-stubbing precedent in tests/. The only tunnel reference (tests/unit/scrub_pii_summary.bats:33-34) stubs the tunnel OUT entirely (has_ssh_tunnel returns 1). So 'add unit tests with ssh stubbed (function shadow on PATH)' is greenfield scaffolding, not an extension — effort is underestimated, and the spoof/reuse/teardown tests must be built from scratch.
- REUSE PORT VERIFICATION IS WEAK. The plan recovers the local port for a reused master by reading a sibling $ctl.port file, but `ssh -O check` only proves the master process is alive — it does NOT prove the forward on $port is still bound (a forward can die while the master lives, or the .port file can be stale vs. the actual forward). The plan does not re-verify the forward is listening on the recorded port before routing prod DB traffic to it.
- ControlPersist=no + -fN -M SEMANTICS UNVERIFIED. The plan asserts the master 'persists across the multiple per-query create_ssh_tunnel calls' but the only per-query caller it names (scrub) is dead. The real callers (dbx entrypoint) call create_ssh_tunnel ONCE per command. With ControlPersist=no the master exits when its last client session ends; for an -fN -M master with no client sessions the persistence behavior across separate dbx invocations is exactly the property that must be proven, and the plan's justification rests on the non-existent per-query reuse pattern.
- STALE-SOCKET FAILURE MODE UNDER-ADDRESSED. New failure mode: a leftover $ctl socket from a crashed run. `ssh -O check` against a dead socket returns nonzero (good), but a stale socket FILE may still exist and block `ssh -M -S $ctl` creation ('control socket already exists'). The plan does not specify cleaning a stale socket path before create, only the .port file on teardown.
