# Persistent wizard (`dbx serve`)

`dbx serve` runs the [wizard GUI](wizards.md) as a **persistent service**. Unlike
`dbx wizard` — which opens your browser once and exits when you save — `dbx serve`
stays up after saves, so it's meant to run under a process manager (systemd) on an
always-on host. Like `dbx wizard`, it binds to `127.0.0.1` (loopback) by default;
pass `--bind 0.0.0.0` (or `DBX_SERVE_BIND`) to expose it on other interfaces and
reach it from across your network.

It's the same UI either way: not just the config form but the full dashboard —
backups, restore, schedule, run history, vault, storage, scrub, and analyze views —
all acting on `~/.config/dbx/config.json` and your backups directly.

```bash
dbx serve                         # bind 127.0.0.1:8080 (loopback), random URL token
dbx serve --bind 0.0.0.0          # expose on all interfaces
dbx serve --bind 0.0.0.0 --allow-host dbx.tailnet.ts.net   # + Host allowlist
dbx serve --no-token              # disable the token gate (proxy/tailnet only)
```

On startup it prints the URL to open:

```
dbx serve — persistent wizard
  URL:    http://127.0.0.1:8080/?token=ab12cd…
  Config: /home/you/.config/dbx/config.json
  Stays up after saves; stop with Ctrl-C or 'systemctl stop'.
  Loopback only (default) — pass --bind 0.0.0.0 to expose on other interfaces.
```

## Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--bind ADDR` | `127.0.0.1` | Bind address. Loopback by default; pass `0.0.0.0` to reach it on other interfaces. |
| `--port N` | `8080` | Listen port. |
| `--token TOKEN` | random | Fixed access token. Omit to get a random one printed at startup. |
| `--no-token` | off | Disable dbx's URL-token gate entirely (see [Authentication](#authentication)). |
| `--allow-host HOST` | _(none)_ | Hostname(s) permitted in the `Host` header (comma-separated). Loopback is always allowed. Hardens against DNS rebinding; **required** to reach a non-loopback `Host` under `--no-token` (see [Authentication](#authentication)). |

Each flag has an environment equivalent, handy for systemd unit files:
`DBX_SERVE_BIND`, `DBX_SERVE_PORT`, `DBX_SERVE_TOKEN`, `DBX_SERVE_NO_TOKEN=true`,
and `DBX_SERVE_ALLOW_HOST`.

## Authentication

By default access is gated by a **token** — *plus* whatever your network already
enforces. That's the right mode when the port is reachable on a LAN or a private
tailnet.

The token rides in the URL (`?token=…`) only on the **first** page load: the
server consumes it to set an `HttpOnly`, `SameSite=Strict` session cookie, the
page strips `?token=` from the address bar, and every request thereafter
authenticates by cookie. So the secret stays out of browser history, the
`Referer` header (responses send `Referrer-Policy: no-referrer`), and the served
HTML. The token has no built-in expiry — it's valid for the life of the server
process; restart `dbx serve` (or rotate `--token`) to invalidate live sessions.

`--no-token` removes dbx's token gate, leaving the fronting layer as the **only**
control. Use it only when something trustworthy sits in front:

- a private network — e.g. binding to a [tailnet](https://tailscale.com) interface so
  only devices on your tailnet can reach the port, or
- an identity proxy — e.g. [Cloudflare Access](https://www.cloudflare.com/zero-trust/products/access/)
  authenticating users before the request ever reaches dbx.

!!! danger "Never expose `--no-token` publicly"
    With `--no-token`, anyone who can reach the port has full access to your backups,
    restores, and config. dbx warns loudly when you combine `--no-token` with a
    non-loopback bind. Only run that mode behind a trusted proxy or on a private
    network — never on a public interface.

### Host-header allowlist (DNS-rebinding)

The server validates the `Host` header on every request — a defence against
[DNS rebinding](https://en.wikipedia.org/wiki/DNS_rebinding), where a victim's
browser is lured to an attacker page that re-points a hostname at your bind
address. Loopback (`127.0.0.1`, `::1`) and `localhost` are always accepted;
beyond that the policy depends on the mode:

- **Token mode, wildcard bind, no `--allow-host`** — permissive (any `Host` is
  served). The token + `SameSite=Strict` cookie already block the rebinding
  attack, so this preserves the out-of-box experience; a startup line nudges you
  to set `--allow-host` to tighten it.
- **`--no-token`** — strict. A non-loopback `Host` is **refused with `403 bad
  host`** unless it is in `--allow-host`. This is the *only* per-request gate in
  `--no-token` mode (there is no cookie, so `SameSite` gives no protection), so
  set `--allow-host` (or `DBX_SERVE_ALLOW_HOST`) to the hostname you reach the
  box by — e.g. its tailnet name or the public hostname your proxy presents.
- **Concrete (non-wildcard) bind** — strict, with the bind address auto-allowed.

```bash
# Reachable as dbx.tailnet.ts.net behind a tailnet, no token:
dbx serve --bind 0.0.0.0 --no-token --allow-host dbx.tailnet.ts.net
```

A fronting reverse proxy (Cloudflare Access, nginx) usually sets `Host` to the
public hostname — add that name to `--allow-host` or the proxied request is
refused.

Note that the wizard can write `config.json`, and the shell-executed `_cmd`
credential fields are CLI-managed for exactly this reason — the server strips
them from client saves so reaching the wizard never becomes code execution on
the host (see [Credential storage](credentials.md#notes)).

One endpoint is held to a stricter bar regardless: the vault "reveal secret"
call (`/api/vault/get`) returns a cleartext credential, so the server serves it
**only to a loopback client with the token gate enabled.** It is refused under
`--no-token`, and to any non-loopback client (the value would otherwise cross
the network in plaintext over non-TLS HTTP). To reveal a stored secret on a
remote `dbx serve`, reach it through an SSH tunnel (`ssh -L 8080:localhost:8080
host`) rather than the network bind — the tunnelled request arrives as loopback.

## Running under systemd

`dbx serve` `exec`s the Python server into the foreground, so a supervisor tracks
and signals it directly. A minimal unit:

```ini
# /etc/systemd/system/dbx-serve.service
[Unit]
Description=dbx persistent wizard
After=network-online.target docker.service
Wants=network-online.target

[Service]
Environment=DBX_SERVE_PORT=8080
# Loopback is the default — expose on other interfaces to be reachable:
Environment=DBX_SERVE_BIND=0.0.0.0
# Behind a tailnet or Cloudflare Access? Drop the token gate — and then you MUST
# allow-list the hostname you reach the box by, or non-loopback requests get 403:
Environment=DBX_SERVE_NO_TOKEN=true
Environment=DBX_SERVE_ALLOW_HOST=dbx.tailnet.ts.net
ExecStart=/usr/local/bin/dbx serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now dbx-serve
```

Because it never exits on save, the service runs until you stop it
(`systemctl stop dbx-serve` or `Ctrl-C` in the foreground).

## In a container / LXC

`dbx serve` is the natural entrypoint for running dbx as an appliance — a long-lived
container or LXC that hosts the wizard and orchestrates backups/restores against the
host Docker daemon. There's an official image —
**[`ghcr.io/steig/dbx`](container.md)** — with a compose / `docker run` recipe; the
[Containerized `dbx serve`](container.md) guide covers the Docker-socket mount,
keychain-free vault backends, and why host networking is recommended. Pair it with
`--no-token` behind a tailnet so the box is reachable by name from your devices
without managing a token.

## See also

- [Interactive wizards](wizards.md) — the one-shot `dbx wizard` and how the GUI is laid out
- [Configuration](configuration.md) — the `config.json` the wizard reads and writes
- [Cloud storage](storage.md) — configuring storage backends from the Storage view
