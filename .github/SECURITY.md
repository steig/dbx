# Security Policy

dbx handles production databases, credentials, SSH tunnels, and encrypted
backups. If you find a vulnerability, please report it privately so it can be
fixed before it is disclosed publicly.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.** Public
issues are visible to everyone and may expose users before a fix is available.

Instead, email **tom@steig.io** with:

- A description of the issue and its potential impact.
- Steps to reproduce, or a proof of concept.
- The dbx version (`dbx version`) and your OS.

If you'd like to encrypt your report, mention it in a first email and we'll
arrange a key.

## Response Expectations

dbx is maintained by a single developer on a best-effort basis. Realistic
expectations:

- **Acknowledgement:** within about a week.
- **Triage and assessment:** as soon as practical after acknowledgement.
- **Fix:** prioritized by severity; there is no guaranteed timeline.

You'll be kept informed of progress, and credited in the release notes if you'd
like (let us know your preference).

## Supported Versions

Security fixes target the **latest released version** on the current release
line. Please upgrade (`dbx update`) before reporting, in case the issue is
already fixed. Older versions are not patched.

## Scope

dbx is a CLI that orchestrates `pg_dump`/`mysqldump`, Docker, SSH, and
`age`/sops, and operates on databases and credentials you supply. In scope:

- Mishandling of credentials, secrets, or encryption keys.
- Insecure defaults, command injection, or path traversal in dbx itself.
- SSH tunnel or temporary-file handling that leaks data or credentials.

Out of scope:

- Vulnerabilities in the underlying tools (PostgreSQL, MySQL, Docker, OpenSSH,
  `age`) — report those upstream.
- Misconfiguration of your own databases, network, or host system.

### Opt-in network exposure

The wizard server is loopback-only and token-authenticated by default. Two
modes deliberately relax this and are **not** for untrusted networks:

- `dbx serve --bind 0.0.0.0` exposes the wizard on all interfaces.
- `--no-token` / `--no-auth` disables authentication.

Using these on a public interface is a misconfiguration, not a dbx
vulnerability. Run them only behind a trusted identity proxy (e.g. Cloudflare
Access) or on a private network (e.g. a tailnet). dbx warns when you combine
them.

Thank you for helping keep dbx and its users safe.
