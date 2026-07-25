# Fix flaky `wizard_server.bats` port-race

**Issue:** #176  
**Status:** Plan (revised). Needs a 2-3 line server change + test rework.  
**Generated:** 2026-06-21 via multi-agent investigate→verify→synthesize workflow.

## Root cause

TOCTOU port race in tests/unit/wizard_server.bats. setup() at line 187 binds an ephemeral port via a Python socket, closes it (releasing the port), then spawns lib/wizard-server.py on that same numeric port at lines 195-217. Between close and the server's re-bind, another process on a loaded macOS CI runner can grab the port, so the server fails to bind and the readiness curl loop (220-223) times out, failing the test. Because allow_reuse_address only helps with TIME_WAIT from the SAME process, it does not protect against a different process taking the freed port. The identical pattern exists a second time in the restart_wiz() helper (238-242), which reuses $WIZ_PORT and re-spawns — the draft missed this; the critique is correct. The server itself never asks the kernel to pick a port and never reports the bound port: lib/wizard-server.py:3403 binds (args.host, args.port) and main() prints nothing, so the test has no way to learn an OS-assigned port today.

## Proposed fix

Option (a), and it is NOT test-only — it needs a small server change plus test rework.

SERVER (lib/wizard-server.py main(), ~3401-3404): after constructing ThreadingHTTPServer, read the actually-bound port via httpd.socket.getsockname()[1] and emit a single stable, prefixed, flushed line to stdout BEFORE serve_forever(), e.g.:
  print(f"DBX_WIZARD_PORT={httpd.server_port}", flush=True)
(httpd.server_port is set by HTTPServer.server_bind from getsockname, so it is the real port even when --port 0.) flush=True is mandatory because stdout is a pipe to a file (not a tty) and is block-buffered; without it the readiness poll could hang. Keep --port required but document that 0 means OS-assigned.

TEST (wizard_server.bats):
1. Delete the line-187 Python free-port helper. Pass --port 0 to the server in setup() and to restart_wiz().
2. After spawning, poll $WIZ_SCRATCH/server.log for the prefixed line and parse it, then set WIZ_PORT. Use a fixed-string grep + cut to stay bash-3.2-safe on macOS:
   for _ in $(seq 1 50); do WIZ_PORT="$(grep -m1 '^DBX_WIZARD_PORT=' "$WIZ_SCRATCH/server.log" 2>/dev/null | cut -d= -f2)"; [[ -n "$WIZ_PORT" ]] && break; sleep 0.1; done
   Fail loudly (cat server.log; return 1) if WIZ_PORT stays empty.
3. Keep the existing curl readiness loop AFTER WIZ_PORT is known.
4. Apply the same poll-the-log discovery inside restart_wiz() (its own fresh log or a truncate before respawn) so its port is rediscovered rather than reused. api() needs no change since it already reads $WIZ_PORT.

This removes the unbind window entirely: the kernel hands the listening socket directly to the server, so no other process can interpose.

PRODUCTION wizard.sh: same TOCTOU but single-user/local, far lower stakes, and a port-0 fix there is larger because the bound port feeds the printed URL and the `ssh -L` line (263-269) — the script would have to poll the server log too. Recommend OUT OF SCOPE for #176 (which scopes to the test) and tracked as a follow-up.

## Affected locations

- tests/unit/wizard_server.bats:187 (free-port helper — the bind/close/respawn TOCTOU)
- tests/unit/wizard_server.bats:195-217 (server spawn + must add log polling for the bound port)
- tests/unit/wizard_server.bats:219-223 (readiness loop — depends on $WIZ_PORT, must read it from the log first)
- tests/unit/wizard_server.bats:233 (api() helper — builds URLs from $WIZ_PORT)
- tests/unit/wizard_server.bats:238-242 (restart_wiz — reuses $WIZ_PORT, same race, needs its own discovery)
- lib/wizard-server.py:3401-3416 (main() — bind, read getsockname, print prefixed flushed port line)
- lib/wizard-server.py:138 (--port argparse; confirm --port 0 is accepted)
- lib/wizard.sh:43-46 + 162 + 207-208 + 263-269 (production: same TOCTOU; OUT OF SCOPE this fix — documented follow-up)

## Steps

- lib/wizard-server.py main(): after ThreadingHTTPServer(...) construction and before serve_forever(), add print(f"DBX_WIZARD_PORT={httpd.server_port}", flush=True). Confirm argparse --port accepts 0.
- wizard_server.bats setup(): remove the line-187 free-port helper; change the spawn to --port 0.
- wizard_server.bats setup(): after capturing WIZ_PID, add a bash-3.2-safe poll loop that greps ^DBX_WIZARD_PORT= from $WIZ_SCRATCH/server.log and cuts the value into WIZ_PORT; fail loudly on timeout.
- wizard_server.bats setup(): keep the curl readiness loop, now running with the parsed WIZ_PORT.
- wizard_server.bats restart_wiz(): change to --port 0; truncate/redirect to a known log and re-run the same DBX_WIZARD_PORT poll to rediscover WIZ_PORT before tests probe.
- Add a repro: run the suite in a tight loop while a background process churns ephemeral binds to maximize port contention; confirm the OLD code flakes and the NEW code does not.
- Soak the patched suite 20-50x on macos-latest (and locally) under that load; expect zero port-bind failures.
- Decide explicitly to leave lib/wizard.sh unchanged for #176; open a follow-up issue for the production TOCTOU (port-0 + log-poll feeding the printed URL/ssh -L line).

## Risks

Low-to-moderate. The printed port line becomes a parse contract between server and test — keep the prefix exact and documented. Forgetting flush=True reintroduces a hang (stdout is a block-buffered pipe, not a tty). The macOS system bash 3.2 quirk (per repo memory) means use fixed-string grep + cut, not ${var//}/regex tricks. restart_wiz must read a FRESH port value, not the stale $WIZ_PORT, or it silently keeps the old race; ensure its log is truncated/separate so the poll reads the new server's line, not the previous one. Server-on-port-0 also affects nothing in production (wizard.sh still passes a concrete port), so no prod behavior change ships. If any other test or fixture greps server.log, verify the new line does not perturb existing assertions.

## Test strategy

Build a deterministic repro FIRST: a port-contention loop (background process repeatedly binding/closing ephemeral ports, or running the suite with high parallelism) that makes the CURRENT bats flake within a handful of iterations — that is the red signal. Then apply the fix and soak: run `nix shell nixpkgs#bats --command bats tests/unit/wizard_server.bats` 20-50x in a loop under the same contention, expecting zero failures (green). Validate both setup() and restart_wiz()-using tests pass. Critically soak on macos-latest CI (the environment where it flaked and where bash 3.2 + load apply), not just local nix bash, since local nix bash masks both the macOS bash quirk and the CI load profile. Confirm no server.log-parsing regressions in the rest of the suite.

## Effort

Small-to-medium, ~2-3 hours. Server change is ~2-3 lines. Test rework is the bulk: two discovery sites (setup + restart_wiz) plus building the repro/soak loop and a macos-latest CI soak. Larger than the draft's 1-2h because of restart_wiz and the macOS soak the critique correctly flagged.

## Open questions

- Confirm fix scope is the test only at the server+test boundary: leave lib/wizard.sh's production TOCTOU for a follow-up issue, or fix prod in the same PR? (Recommendation: follow-up — #176 scopes to the test and prod is single-user/lower-stakes.)
- Exact port-line prefix/format — DBX_WIZARD_PORT=<n> proposed; any preference (e.g. matching an existing log convention)?
- Should the server emit the port line for ALL invocations (including dbx serve / dbx wizard in production) or be gated behind a flag? Emitting always is simplest and harmless, but confirm no downstream parser is surprised.
- Is httpd.server_port the agreed source for the bound port vs. httpd.socket.getsockname()[1]? (server_port is set from getsockname during server_bind, so equivalent.)
