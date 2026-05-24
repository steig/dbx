---
hide:
  - toc
---

# Config builder

Build your `config.json` here without installing dbx. Add hosts, choose direct or SSH-tunnel connections, declare databases to back up, optionally configure cloud storage, then **Copy** or **Download** the result and drop it at `~/.config/dbx/config.json`. Passwords are never collected — the generated config references `dbx vault set <alias>` commands you'll run after.

Same form runs locally via `dbx wizard` once you've installed dbx, if you prefer a browser-driven flow over the terminal wizards. See [Interactive wizards](wizards.md#dbx-wizard-browser-mode) for that variant.

<div data-mode="static">
--8<-- "lib/wizard-form.html"
</div>
