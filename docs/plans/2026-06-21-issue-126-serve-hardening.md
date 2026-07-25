# Harden `dbx serve` network exposure

**Issue:** #126  
**Status:** Plan (pre-implementation). One BLOCKING maintainer decision — see Open questions #1.  
**Generated:** 2026-06-21 via multi-agent investigate→verify→synthesize workflow.

## Root cause

Two distinct exposure defects in `dbx serve`, both verified against the code:

1. Insecure default bind. `cmd_serve` defaults bind to all-interfaces: `local bind="${DBX_SERVE_BIND:-0.0.0.0}"` (lib/wizard.sh:305). The --help text (lib/wizard.sh:327), the startup banner URL (lib/wizard.sh:385/387), and docs/serve.md (lines 5-7, 14, 23, 32) all advertise 0.0.0.0 as the default, so a bare `dbx serve` on any host is reachable on every interface with only the URL/cookie token in front. The one-shot `dbx wizard` and the Python server default both bind loopback (lib/wizard-server.py:139-140) — only serve flips it open.

2. No Host-header validation = DNS-rebinding vector for the ungated endpoints. The Python server never reads the HTTP Host header in the request path (grep confirms the only "Host" hits are comments). do_GET (lib/wizard-server.py:2452-2456) and do_POST (lib/wizard-server.py:2773-2777) gate solely on valid_token(self) (lib/wizard-server.py:2197-2207), which checks the URL token / session cookie. In token mode SameSite=Strict + the token never appearing in served HTML largely mitigates rebinding. But in --no-auth mode (lib/wizard.sh:356-357 -> server line 2202 `if args.no_auth: return True`) there is NO per-request gate, and SameSite gives ZERO protection there because no cookie exists — so a victim browser lured to an attacker page that rebinds DNS to the serve IP can drive the state-changing endpoints (backups, restores, /save, /api/config-save) with no credential.

CORRECTION to the draft's scope (verified): /api/vault/get is NOT ungated — it is already loopback-gated at lib/wizard-server.py:2695 (`if args.no_auth or not is_loopback_client(self.client_address[0])` -> 403, shipped as #124 in v0.36.0). The draft's sweeping "drive EVERY endpoint" is inaccurate; the real exposure is the state-changing POSTs that have no gate. Importantly, DNS-rebinding does NOT bypass client_address loopback checks: the rebound request still originates from the victim's real (non-loopback) IP, so is_loopback_client gates are inherently safe against rebinding and need no change. The new Host check is therefore needed ONLY for the no-gate endpoints (the --no-auth state-changing path), which sharpens the fix.

Container interaction (verified): the official image pins DBX_SERVE_BIND=0.0.0.0 in the Dockerfile ENV (docker/Dockerfile:57) and docs use `--network host` (docker/docker-compose.yml network_mode: host; docs/container.md "Remote sources need host networking"). The env var overrides the bash default, so flipping the code default to 127.0.0.1 does NOT break the container. With --network host the wizard binds the host's :8080 directly, so a strict Host policy WOULD 403 every non-loopback request to the just-shipped v0.37.0 container (#180/#184) unless an allowlist is set — this UX call must be made by the maintainer, not the implementer.

## Proposed fix

Two coordinated, opt-in-to-expose changes. Both land in the same release with a clear breaking-change note.

A) Flip the serve default to loopback (lib/wizard.sh:305).
- Change `local bind="${DBX_SERVE_BIND:-0.0.0.0}"` to default `127.0.0.1`. Exposing now requires explicit --bind/DBX_SERVE_BIND.
- Update --help (lib/wizard.sh:327), the banner (lib/wizard.sh:385/387), and serve.md (5-7, 14, 23, 32) to the new default. The banner already prints `http://${bind}:${port}` so it self-corrects, but ADD a new warning for the inverse case: when --no-token is set AND bind is loopback (the new default), warn "only localhost can reach this; pass --bind to expose" — this is the systemd/tailnet user who will otherwise be silently broken.
- Container unaffected: Dockerfile:57 pins the env, which overrides the bash default. Keep line 57; fix the now-stale comment at Dockerfile:52-53 ("Serve binds all interfaces by default" is false post-flip — reword to "the container forces 0.0.0.0 via DBX_SERVE_BIND below so it is reachable in its own netns").
- Update the documented systemd unit (serve.md:94-97) to add `Environment=DBX_SERVE_BIND=0.0.0.0` — otherwise the shipped example becomes an unreachable no-op appliance.

B) Add Host-header validation in the Python server, ABOVE valid_token in both verbs — the gate that gives --no-auth a real per-request defense against DNS rebinding.
- Add `--allow-host` to parse_args (lib/wizard-server.py:137), `action="append", default=None`, also accept comma-split values.
- Add a module-level helper beside is_loopback_client (lib/wizard-server.py:~2176), e.g. `host_header_allowed(handler, args)`. It MUST read `handler.headers.get("Host")` (BaseHTTPRequestHandler has no `.host`); reject if absent/empty; strip the port (handle `[::1]:8080` bracketed IPv6); lowercase; allow if the Host is an IP literal that parses as loopback (reuse the ipaddress parsing discipline of is_loopback_client but apply it to the Host STRING, not client_address — keep the two concepts distinct); allow if it matches the allowlist. Allowlist policy: explicit --allow-host wins; with a concrete non-wildcard --host bind, also auto-allow that bind addr; with a wildcard bind (0.0.0.0/::) and no --allow-host, the policy default is the OPEN MAINTAINER QUESTION below — implement the chosen branch behind one clearly named constant so it is a one-line flip.
- Insert `if not host_header_allowed(self, args): self._send(403, "bad host"); return` at the very top of do_GET (above line 2454) and do_POST (above line 2775).
- Wire DBX_SERVE_ALLOW_HOST + --allow-host through cmd_serve (lib/wizard.sh arg loop + exec splice) so container/tailnet operators can name their reachable hostname. Document in serve.md Authentication and the container.md host-net section (esp. for --no-token + --network host, where the operator must set DBX_SERVE_ALLOW_HOST to their tailnet/hostname).

Do NOT touch /api/vault/get (line 2695) — already correctly gated and rebinding-safe via client_address.

## Affected locations

- /Users/tom.steig/code/dbx/lib/wizard.sh:305 (default bind -> 127.0.0.1)
- /Users/tom.steig/code/dbx/lib/wizard.sh:309-345 (arg loop: add --allow-host + DBX_SERVE_ALLOW_HOST)
- /Users/tom.steig/code/dbx/lib/wizard.sh:320-340 (--help text)
- /Users/tom.steig/code/dbx/lib/wizard.sh:384-395 (startup banner + warnings, incl. new loopback-default nudge)
- /Users/tom.steig/code/dbx/lib/wizard.sh:399-409 (exec arg list: splice --allow-host)
- /Users/tom.steig/code/dbx/lib/wizard-server.py:137-200 (parse_args: add --allow-host)
- /Users/tom.steig/code/dbx/lib/wizard-server.py:2162-2175 (is_loopback_client — reference only; do NOT modify; new helper sits beside it)
- /Users/tom.steig/code/dbx/lib/wizard-server.py:2452-2456 (do_GET: Host gate ABOVE valid_token)
- /Users/tom.steig/code/dbx/lib/wizard-server.py:2773-2777 (do_POST: Host gate ABOVE valid_token)
- /Users/tom.steig/code/dbx/docker/Dockerfile:52-53 (stale 'binds all interfaces by default' comment — fix)
- /Users/tom.steig/code/dbx/docker/Dockerfile:57 (keep DBX_SERVE_BIND=0.0.0.0)
- /Users/tom.steig/code/dbx/docs/serve.md:5-38 (default + flag table + example URLs)
- /Users/tom.steig/code/dbx/docs/serve.md:40-79 (Authentication: document Host check + --no-auth rebinding rationale)
- /Users/tom.steig/code/dbx/docs/serve.md:81-106 (systemd unit MUST add DBX_SERVE_BIND=0.0.0.0)
- /Users/tom.steig/code/dbx/docs/container.md (host-net section + serve.md cross-ref: DBX_SERVE_ALLOW_HOST guidance)
- /Users/tom.steig/code/dbx/CHANGELOG.md (breaking-change migration note)
- /Users/tom.steig/code/dbx/man/man1/dbx.1 (serve subsection; NOTE: there is NO dedicated dbx-serve.1 man page — do not invent one)

## Steps

- lib/wizard.sh:305 — change default bind to 127.0.0.1.
- lib/wizard.sh:309-345 — add `--allow-host`/`--allow-host=*` cases and `DBX_SERVE_ALLOW_HOST` env to the arg loop, mirroring existing --bind handling. Avoid new ${var//PAT/REP} forms unless tested on macOS bash 3.2 (per memory).
- lib/wizard.sh:399-409 — build an `allow_host_args` array and splice `--allow-host VALUE` into the exec when set.
- lib/wizard.sh:320-340 — update --help: loopback is the new default; document --allow-host + DBX_SERVE_ALLOW_HOST.
- lib/wizard.sh:384-395 — banner/warnings: keep the existing 0.0.0.0 warnings; ADD a loopback+--no-token nudge ('only localhost can reach this; pass --bind to expose'); for --no-token + non-loopback bind recommend --allow-host.
- lib/wizard-server.py:137 — add `p.add_argument('--allow-host', action='append', default=None)` (comma-split accepted).
- lib/wizard-server.py:~2176 — add host_header_allowed(handler, args): read handler.headers.get('Host'); reject empty; strip port incl. bracketed IPv6; lowercase; allow loopback IP-literal Hosts; allow allowlist/concrete-bind matches; wildcard-bind-no-allowlist branch behind one named constant (policy = maintainer question).
- lib/wizard-server.py:2454 — add the Host gate ABOVE valid_token in do_GET (403 on fail).
- lib/wizard-server.py:2775 — same Host gate ABOVE valid_token in do_POST.
- docker/Dockerfile:52-53 — fix the stale 'binds all interfaces by default' comment; keep line 57.
- docs/serve.md:5-38 — loopback default, --bind to expose, --allow-host/DBX_SERVE_ALLOW_HOST; fix example URLs (14/23/32).
- docs/serve.md:40-79 — Authentication: document the Host check and the --no-auth DNS-rebinding rationale (note SameSite gives no protection in --no-auth, so Host is the sole gate there).
- docs/serve.md:94-97 — add Environment=DBX_SERVE_BIND=0.0.0.0 to the systemd unit (and DBX_SERVE_ALLOW_HOST guidance for --no-token).
- docs/container.md — in the host-net section, instruct operators to set DBX_SERVE_ALLOW_HOST to their reachable hostname/tailnet name when using --no-token under --network host.
- man/man1/dbx.1 — update the serve subsection for the new default + flags. NOTE: no dbx-serve.1 exists; do not create one. Follow the manual release process (CHANGELOG + the man .TH bumps) per project memory; there is no VERSION file.
- CHANGELOG.md — record BOTH behavior changes as breaking with a migration note.
- Add bats coverage (see testStrategy).

## Risks

Breaking change #1 (bind flip): host (non-container) `dbx serve` users relying on the implicit 0.0.0.0 default lose remote reachability after upgrade. The shipped systemd example (serve.md:94-97) becomes an unreachable no-op until DBX_SERVE_BIND=0.0.0.0 is added — fix the doc in the same PR or it ships self-contradicting. Container users unaffected (Dockerfile pins the env). | Breaking change #2 (Host check on wildcard bind): if the wildcard-no-allowlist policy is strict-403, the just-shipped v0.37.0 container (host-net, reached by hostname/tailnet name) 403s every non-loopback request out of the box until the operator sets DBX_SERVE_ALLOW_HOST — a regression for #180/#184. This is why the policy must be a maintainer decision, implemented behind one named constant. | Cloudflare Access / reverse proxies set Host to the public hostname — operators MUST add it to --allow-host or the proxy path 403s; document prominently. | Header parsing edge cases: bracketed IPv6 (`[::1]:8080`), missing Host (HTTP/1.0), default-port-omitted Host must all be handled or they wrongly 403 — needs unit coverage. Do not conflate Host (a string from the header) with client_address (an IP); is_loopback_client stays untouched. | Ordering: the Host check MUST sit ABOVE valid_token in both verbs; if placed after, --no-auth still has no gate. | --no-auth has no cookie, so SameSite=Strict provides zero CSRF/rebinding protection there — the Host parser is the only defense, raising the bar on getting it exactly right.

## Test strategy

bats runner: `nix shell nixpkgs#bats --command bats` (per memory; no checked-in justfile/flake). Bash unit-level: (1) cmd_serve default bind is 127.0.0.1 when DBX_SERVE_BIND unset — assert by capturing exec argv with a stubbed python (or via --help text); (2) DBX_SERVE_BIND and --bind still override; (3) DBX_SERVE_ALLOW_HOST/--allow-host is spliced into the exec argv. Integration against the real Python server (spin up + curl): (4) loopback Host on loopback bind -> 200; (5) bogus Host (attacker.example) on a wildcard bind under the chosen policy -> 403 even WITH a valid token; (6) --no-auth + non-allowed Host -> 403 (the core rebinding assertion: proves --no-auth now has a per-request gate); (7) Host matching --allow-host -> 200; (8) bracketed IPv6 `[::1]` Host and missing-Host (HTTP/1.0) cases; (9) regression: /api/vault/get still 403s under --no-auth and to non-loopback client_address (unchanged). Reuse the existing wizard-server bats harness if present (check tests/ for how the server is launched). Run unit tests on macOS bash 3.2 (macos-latest CI) for any new parameter-substitution per the bash-3.2 memory note.

## Effort

Medium — ~1 day. Server-side Host helper + two gate insertions + one argparse flag are small and isolated; the bash flag/env plumbing mirrors existing --bind handling. The bulk is behavior-change coordination: docs (serve.md incl. the systemd unit, container.md), the dbx.1 man subsection + CHANGELOG per the manual release process, the stale Dockerfile comment, and bats coverage for Host-parsing edge cases and the --no-auth rebinding assertion. No architectural change; both fixes are additive and opt-in-to-expose. The one true gate on shipping is the maintainer policy decision for the wildcard-bind default (below).

## Open questions

- BLOCKING — wildcard-bind (0.0.0.0/::) + no --allow-host Host policy. Strict-403 (safest; rebinding-proof) immediately 403s every existing remote deploy AND the v0.37.0 container out of the box, vs. warn-and-allow (preserves current UX; weaker, but token + SameSite still cover token mode — only --no-auth is exposed to rebinding). Recommendation: warn-and-allow when token auth is ON; strict-403 (require --allow-host or --allow-host=* sentinel) when --no-auth is set, since that is the only path with no other gate. Implement behind one named constant. Maintainer must sign off — do not let the implementer pick the default.
- Should the official image ship a default DBX_SERVE_ALLOW_HOST, or stay unset and force operators to declare their hostname? Tied to the policy above: under the recommended split, the token-mode container is fine unset; a --no-token container needs the operator to set it. Confirm the desired out-of-box container UX.
- Should cmd_serve auto-populate --allow-host from the system hostname / a detected tailnet (*.ts.net) interface to reduce friction, or stay fully explicit? Auto-detection adds a heuristic that can be wrong; recommend explicit.
- Validate Origin/Referer for state-changing POSTs in addition to Host? In token mode SameSite=Strict already blocks cross-site cookie POSTs; in --no-auth there is no cookie so neither SameSite nor Origin-from-cookie helps — Host is the gate. Likely Host-only is sufficient; worth a maintainer call.
- Ship A (bind flip) and B (Host check) together (cleaner, one breaking note) vs. stage B first behind opt-in then A? Recommend together with a single prominent CHANGELOG migration note.
