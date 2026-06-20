# Persistent wizard (`dbx serve`)

`dbx serve` runs the [wizard GUI](wizards.md) as a **persistent, network-reachable
service**. Unlike `dbx wizard` — which binds to `127.0.0.1`, opens your browser once,
and exits when you save — `dbx serve` stays up after saves and listens on all
interfaces, so it's meant to run under a process manager (systemd) on an always-on
host and be reached from anywhere on your network.

It's the same UI either way: not just the config form but the full dashboard —
backups, restore, schedule, run history, vault, storage, scrub, and analyze views —
all acting on `~/.config/dbx/config.json` and your backups directly.

```bash
dbx serve                         # bind 0.0.0.0:8080, random URL token (printed)
dbx serve --port 9000             # different port
dbx serve --no-token              # disable the token gate (proxy/tailnet only)
```

On startup it prints the URL to open:

```
dbx serve — persistent wizard
  URL:    http://0.0.0.0:8080/?token=ab12cd…
  Config: /home/you/.config/dbx/config.json
  Stays up after saves; stop with Ctrl-C or 'systemctl stop'.
```

## Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--bind ADDR` | `0.0.0.0` | Bind address. `0.0.0.0` is reachable on all interfaces. |
| `--port N` | `8080` | Listen port. |
| `--token TOKEN` | random | Fixed access token. Omit to get a random one printed at startup. |
| `--no-token` | off | Disable dbx's URL-token gate entirely (see [Authentication](#authentication)). |

Each flag has an environment equivalent, handy for systemd unit files:
`DBX_SERVE_BIND`, `DBX_SERVE_PORT`, `DBX_SERVE_TOKEN`, and `DBX_SERVE_NO_TOKEN=true`.

## Authentication

By default access is gated by a **URL token** — every request must carry
`?token=…` — *plus* whatever your network already enforces. That's the right mode
when the port is reachable on a LAN or a private tailnet.

`--no-token` removes dbx's token gate, leaving the fronting layer as the **only**
control. Use it only when something trustworthy sits in front:

- a private network — e.g. binding to a [tailnet](https://tailscale.com) interface so
  only devices on your tailnet can reach the port, or
- an identity proxy — e.g. [Cloudflare Access](https://www.cloudflare.com/zero-trust/products/access/)
  authenticating users before the request ever reaches dbx.

!!! danger "Never expose `--no-token` publicly"
    With `--no-token`, anyone who can reach the port has full access to your backups,
    restores, and config. dbx warns loudly when you combine `--no-token` with
    `--bind 0.0.0.0`. Only run that mode behind a trusted proxy or on a private
    network — never on a public interface.

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
# Behind a tailnet or Cloudflare Access? Drop the token gate:
Environment=DBX_SERVE_NO_TOKEN=true
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
host Docker daemon. Pair it with `--no-token` behind a tailnet so the box is reachable
by name from your devices without managing a token, and add a timer that
fast-forwards the checkout and restarts the service to keep it current.

## See also

- [Interactive wizards](wizards.md) — the one-shot `dbx wizard` and how the GUI is laid out
- [Configuration](configuration.md) — the `config.json` the wizard reads and writes
- [Cloud storage](storage.md) — configuring storage backends from the Storage view
