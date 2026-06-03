#!/usr/bin/env python3
# lib/wizard-server.py - HTTP server backing `dbx wizard`.
#
# Spawned by lib/wizard.sh. Serves the composed wizard HTML and handles the
# config-save POST. Bound to 127.0.0.1 only; every request must carry a URL
# token matching the one passed via --token. The wizard.sh trap kills this
# process on exit.

import argparse
import datetime
import http.server
import json
import os
import re
import secrets
import shutil
import socketserver
import subprocess
import threading
import urllib.parse


# host/db identifier shape — kept literal-translated from host_alias_valid in
# the bash side (tests/unit/host_add.bats checks dots/dashes/underscores).
IDENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
# Target-name shape used by --name. dbx itself only allows the same characters.
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
# Source shape: `<host>/<db>/latest` or `<host>/<db>/<filename>`.
SOURCE_HOSTDB_RE = re.compile(
    r"^([A-Za-z0-9][A-Za-z0-9._-]{0,63})/([A-Za-z0-9][A-Za-z0-9._-]{0,63})/(latest|[A-Za-z0-9._-]{1,128}\.sql\.zst(?:\.age|\.gpg)?)$"
)
# Vault key shape — slightly looser than IDENT_RE (no leading-char rule) so
# users can store `_internal`-style keys if their existing config has them.
# Length cap at 64 keeps argv + audit-log rows bounded.
VAULT_KEY_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
# age public-key recipient shape per the age spec (Bech32-encoded). Keeping
# the range loose (50-80 chars after `age1`) covers the 58-char canonical
# form and any future variant without becoming a length-counting hassle.
AGE_RECIPIENT_RE = re.compile(r"^age1[a-z0-9]{50,80}$")
# Cap vault values at 4096 bytes — matches the spec; the system keychain on
# macOS can take longer values but 4KiB is sufficient for any reasonable
# password / token / connection string.
VAULT_VALUE_MAX_BYTES = 4096


class Job:
    """One running `dbx restore` process. Lines accumulate in memory; SSE
    consumers read with an offset. Multiple SSE consumers are OK — each
    independently tracks how many lines it has already sent."""

    def __init__(self, popen: subprocess.Popen):
        self.popen = popen
        self.lines: list[str] = []
        self.cv = threading.Condition()
        self.finished = False
        self.exit_code: int | None = None
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self):
        try:
            assert self.popen.stdout is not None
            for line in self.popen.stdout:
                with self.cv:
                    self.lines.append(line.rstrip("\n"))
                    self.cv.notify_all()
        finally:
            self.popen.wait()
            with self.cv:
                self.finished = True
                self.exit_code = self.popen.returncode
                self.cv.notify_all()

    def cancel(self) -> bool:
        if self.popen.poll() is not None:
            return False
        self.popen.terminate()
        try:
            self.popen.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.popen.kill()
        return True


JOBS: dict[str, Job] = {}
JOBS_LOCK = threading.Lock()


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--host", default="127.0.0.1",
                   help="Bind address (default 127.0.0.1; e.g. 0.0.0.0 for `dbx serve`)")
    p.add_argument("--token", required=True)
    p.add_argument("--html", required=True, help="Path to wizard.html shell")
    p.add_argument("--form-fragment", required=True, help="Path to wizard-form.html")
    p.add_argument("--backups-fragment", required=True, help="Path to wizard-backups.html")
    p.add_argument("--backup-fragment", required=True, help="Path to wizard-backup.html")
    p.add_argument("--restore-fragment", required=True, help="Path to wizard-restore.html")
    p.add_argument("--config-path", required=True, help="Where to write config.json on POST /save")
    p.add_argument("--data-dir", required=True, help="Root for backup enumeration (DATA_DIR)")
    p.add_argument("--dbx-bin", required=True, help="Path to the dbx binary to invoke for restores")
    p.add_argument("--lib-dir", required=True, help="Path to dbx lib/ (sourced for schedule helpers)")
    p.add_argument("--schedule-fragment", required=True, help="Path to wizard-schedule.html")
    p.add_argument(
        "--runs-fragment",
        required=True,
        help="Path to wizard-runs.html (audit-log Runs view)",
    )
    p.add_argument(
        "--dashboard-fragment",
        required=True,
        help="Path to wizard-dashboard.html (landing-tab health view)",
    )
    p.add_argument(
        "--vault-fragment",
        required=True,
        help="Path to wizard-vault.html (vault management view)",
    )
    p.add_argument(
        "--storage-fragment",
        required=True,
        help="Path to wizard-storage.html (storage usage + retention sweep view)",
    )
    p.add_argument(
        "--scrub-fragment",
        required=True,
        help="Path to wizard-scrub.html (Scrub manifest editor view)",
    )
    p.add_argument(
        "--analyze-fragment",
        required=True,
        help="Path to wizard-analyze.html (Analyze view: table stats + PII pre-scan)",
    )
    p.add_argument(
        "--audit-dir",
        default=os.environ.get(
            "DBX_AUDIT_DIR",
            os.path.join(os.environ.get("HOME", ""), ".local", "share", "dbx"),
        ),
        help="Directory containing audit.log (default: $DBX_AUDIT_DIR or ~/.local/share/dbx)",
    )
    p.add_argument("--done-marker", default=None,
                   help="If set, touched after a successful save (ephemeral wizard "
                        "exits on it). Omitted by `dbx serve` to stay persistent.")
    return p.parse_args()


def _read_host_safety_map(config_path):
    """Return {host_alias: 'prod'|'stage'|'local'} from config.json. Hosts
    that omit the field default to 'local'. Malformed values also default
    to 'local' (matches the bash-side host_safety helper). Returns {} if
    the config can't be read."""
    safety: dict[str, str] = {}
    if not config_path or not os.path.isfile(config_path):
        return safety
    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return safety
    if not isinstance(cfg, dict):
        return safety
    hosts = cfg.get("hosts")
    if not isinstance(hosts, dict):
        return safety
    for h, block in hosts.items():
        if not isinstance(block, dict):
            continue
        s = block.get("safety", "local")
        safety[h] = s if s in ("prod", "stage", "local") else "local"
    return safety


# ---------------------------------------------------------------------------
# Scrub: per-host status, manifest read/write, and init/check shell-outs.
#
# Hosts in config.json are stored object-keyed-by-alias (see
# wizard-form.html:1010-1044). Every helper in lib/scrub.sh looks the host
# up by key — so the wizard's scrub side speaks the same shape. A legacy
# list-of-{alias,...} form is tolerated for forward compatibility.
# ---------------------------------------------------------------------------


def _read_hosts_object(config_path: str) -> dict:
    """Return the hosts block as {alias: block}. {} on missing / malformed."""
    if not config_path or not os.path.isfile(config_path):
        return {}
    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(cfg, dict):
        return {}
    hosts = cfg.get("hosts")
    if isinstance(hosts, dict):
        return {k: v for k, v in hosts.items()
                if isinstance(k, str) and IDENT_RE.match(k) and isinstance(v, dict)}
    if isinstance(hosts, list):
        out = {}
        for h in hosts:
            if isinstance(h, dict) and isinstance(h.get("alias"), str) \
                    and IDENT_RE.match(h["alias"]):
                out[h["alias"]] = h
        return out
    return {}


def _scrub_manifest_path_for(config_path: str, host_block) -> str | None:
    """Mirror lib/scrub.sh:scrub_manifest_path. Absolute path declared at
    hosts.<alias>.scrub.manifest, resolved relative to the config-file
    directory when stored as a relative path. None when unset."""
    if not isinstance(host_block, dict):
        return None
    scrub = host_block.get("scrub")
    if not isinstance(scrub, dict):
        return None
    raw = scrub.get("manifest")
    if not isinstance(raw, str) or not raw:
        return None
    if os.path.isabs(raw):
        return raw
    return os.path.join(os.path.dirname(config_path), raw)


def _scrub_required_flag(host_block) -> bool:
    """True iff hosts.<alias>.scrub.required is the JSON boolean true. Same
    flag scrub.sh:scrub_gate_active() reads to decide whether to enforce."""
    if not isinstance(host_block, dict):
        return False
    scrub = host_block.get("scrub")
    if not isinstance(scrub, dict):
        return False
    return scrub.get("required") is True


def scrub_status(config_path: str) -> list:
    """One entry per configured host: manifest path/existence, required
    flag, configured database names (so the Init picker doesn't ask the
    user to type a name they already declared elsewhere)."""
    out = []
    hosts = _read_hosts_object(config_path)
    for alias in sorted(hosts):
        block = hosts[alias]
        manifest_path = _scrub_manifest_path_for(config_path, block)
        manifest_exists = bool(manifest_path) and os.path.isfile(manifest_path)
        databases_field = block.get("databases")
        if isinstance(databases_field, dict):
            databases = sorted(databases_field.keys())
        elif isinstance(databases_field, list):
            # Tolerate the wizard-form intermediate shape
            names = [d.get("name") for d in databases_field
                     if isinstance(d, dict) and isinstance(d.get("name"), str)]
            databases = sorted(n for n in names if n)
        else:
            databases = []
        out.append({
            "alias": alias,
            "type": block.get("type") if isinstance(block.get("type"), str) else None,
            "safety": block.get("safety") if block.get("safety") in ("prod", "stage", "local") else "local",
            "manifest_path": manifest_path,
            "manifest_exists": manifest_exists,
            "scrub_required": _scrub_required_flag(block),
            "databases": databases,
        })
    return out


def read_scrub_manifest(config_path: str, host: str):
    """Return (manifest_json_or_None, resolved_path_or_None, error_or_None).
    No manifest configured → (None, None, None). Configured but file missing
    → (None, path, None). Parse error → (None, path, message)."""
    hosts = _read_hosts_object(config_path)
    block = hosts.get(host)
    if block is None:
        return None, None, f"host '{host}' is not configured"
    path = _scrub_manifest_path_for(config_path, block)
    if path is None:
        return None, None, None
    if not os.path.isfile(path):
        return None, path, None
    try:
        with open(path) as f:
            return json.load(f), path, None
    except (OSError, json.JSONDecodeError) as e:
        return None, path, f"could not read manifest at {path}: {e}"


# Strategy names recognised by lib/scrub.sh:scrub_validate_manifest. Match
# the case-arm list at scrub.sh:467-498. Used to gate /api/scrub/save before
# we touch the filesystem.
# Must match the case-arm list in lib/scrub.sh:scrub_validate_manifest.
# Drift here means the wizard accepts a manifest the CLI then rejects.
SCRUB_STRATEGIES = {
    "fake_email", "fake_phone", "fake_ip", "fake_name",
    "redact", "truncate", "shift_date", "passthrough", "jsonb_scrub_paths",
}


def _validate_manifest_shape(manifest) -> str | None:
    """Lightweight pre-validation: catches the shape errors that would
    cause `dbx scrub validate` to reject the file. Returns None on
    accept, or a message describing the first problem. The bash side
    validates again on next CLI use; this is just to give the wizard
    instant feedback instead of writing a broken file."""
    if not isinstance(manifest, dict):
        return "manifest must be a JSON object"
    if "version" in manifest and not isinstance(manifest["version"], str):
        return "manifest.version must be a string"
    tables = manifest.get("tables", {})
    if not isinstance(tables, dict):
        return "manifest.tables must be an object"
    for tname, tbody in tables.items():
        if not isinstance(tname, str) or not tname:
            return "table names must be non-empty strings"
        if not isinstance(tbody, dict):
            return f"tables.{tname} must be an object"
        has_no_pii = tbody.get("no_pii") is True
        has_columns = isinstance(tbody.get("columns"), dict) and tbody["columns"]
        if has_no_pii and has_columns:
            return f"tables.{tname}: no_pii and columns are mutually exclusive"
        if has_no_pii:
            if not isinstance(tbody.get("reason"), str) or not tbody["reason"]:
                return f"tables.{tname}: no_pii requires a non-empty reason"
            continue
        if not has_columns:
            # Mirror lib/scrub.sh:scrub_validate_manifest which rejects
            # tables with neither no_pii=true nor a non-empty columns
            # object: "manifest: table 'X' has neither no_pii=true nor a
            # 'columns' object". We have to reject here too — otherwise
            # the wizard's save succeeds and the manifest then fails the
            # CLI's validate step on the very next `dbx scrub` command.
            return (f"tables.{tname}: must declare either no_pii=true (with a "
                    f"reason) or at least one column under 'columns'")
        for cname, cbody in tbody["columns"].items():
            if not isinstance(cname, str) or not cname:
                return f"tables.{tname}: column names must be non-empty strings"
            if not isinstance(cbody, dict):
                return f"tables.{tname}.columns.{cname} must be an object"
            strat = cbody.get("strategy")
            if not isinstance(strat, str) or strat not in SCRUB_STRATEGIES:
                return (f"tables.{tname}.columns.{cname}: strategy must be one of "
                        f"{sorted(SCRUB_STRATEGIES)}")
    return None


def write_scrub_manifest(target_path, config_path: str, manifest,
                         host_for_config) -> tuple[bool, str | None]:
    """Atomically write `manifest` to `target_path`. When `host_for_config`
    is a non-empty string, also patch config.json so
    hosts.<host>.scrub.manifest points at the file. The path must resolve
    to a location under $HOME or the config directory."""
    err = _validate_manifest_shape(manifest)
    if err is not None:
        return False, err
    if not isinstance(target_path, str) or not target_path:
        return False, "manifest path is required"
    if "\x00" in target_path:
        return False, "manifest path contains NUL"
    # Validate host_for_config BEFORE any disk I/O. The old order wrote
    # the manifest first and then rejected a bad host alias, which left
    # an orphaned file the user was told didn't save.
    if host_for_config is not None and host_for_config != "":
        if not isinstance(host_for_config, str) or not IDENT_RE.match(host_for_config):
            return False, "host alias has invalid characters"

    config_dir = os.path.realpath(os.path.dirname(config_path))
    home_raw = os.environ.get("HOME") or ""
    home = os.path.realpath(home_raw) if home_raw else ""
    abs_target = target_path if os.path.isabs(target_path) \
        else os.path.join(config_dir, target_path)
    parent = os.path.realpath(os.path.dirname(abs_target) or ".")
    under_config = parent == config_dir or parent.startswith(config_dir + os.sep)
    under_home = bool(home) and (parent == home or parent.startswith(home + os.sep))
    if not (under_config or under_home):
        return False, "manifest path must be under the config directory or $HOME"
    if not abs_target.endswith(".json"):
        return False, "manifest path must end with .json"
    # Also realpath the target itself when it already exists, so a symlink
    # at abs_target pointing outside the allowed roots is caught (only the
    # parent dir was being resolved before — a symlinked target slipped
    # past the containment check). New files have no symlink to resolve.
    if os.path.lexists(abs_target):
        resolved_target = os.path.realpath(abs_target)
        resolved_parent = os.path.dirname(resolved_target)
        resolved_under_config = (resolved_parent == config_dir
                                 or resolved_parent.startswith(config_dir + os.sep))
        resolved_under_home = bool(home) and (resolved_parent == home
                                              or resolved_parent.startswith(home + os.sep))
        if not (resolved_under_config or resolved_under_home):
            return False, "manifest path resolves (via symlink) outside $HOME / config dir"

    tmp_path = abs_target + ".wizard-tmp"
    try:
        os.makedirs(os.path.dirname(abs_target), exist_ok=True)
        with open(tmp_path, "w") as f:
            json.dump(manifest, f, indent=2)
            f.write("\n")
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, abs_target)
    except OSError as e:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        return False, f"write failed: {e}"

    # host_for_config was validated at the top of the function. Treat
    # missing/empty as "manifest saved, don't touch config.json".
    if not isinstance(host_for_config, str) or not host_for_config:
        return True, None

    try:
        if os.path.isfile(config_path):
            with open(config_path) as f:
                cfg = json.load(f)
            if not isinstance(cfg, dict):
                return False, "existing config.json is not a JSON object"
        else:
            cfg = {}
    except (OSError, json.JSONDecodeError) as e:
        return False, f"could not read config.json: {e}"

    hosts = cfg.get("hosts")
    if not isinstance(hosts, dict):
        return False, "cannot set scrub.manifest: hosts block missing or not in object form"
    block = hosts.get(host_for_config)
    if not isinstance(block, dict):
        return False, f"cannot set scrub.manifest: host '{host_for_config}' not in config"

    # Store as a config-relative path when possible so the file moves with
    # the config dir — same convention scrub_manifest_path() uses.
    if abs_target == config_dir or abs_target.startswith(config_dir + os.sep):
        stored = os.path.relpath(abs_target, config_dir)
    else:
        stored = abs_target

    scrub_block_raw = block.get("scrub")
    scrub_block = scrub_block_raw if isinstance(scrub_block_raw, dict) else {}
    scrub_block["manifest"] = stored
    block["scrub"] = scrub_block

    cfg_tmp = config_path + ".wizard-tmp"
    try:
        with open(cfg_tmp, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        os.chmod(cfg_tmp, 0o600)
        os.replace(cfg_tmp, config_path)
    except OSError as e:
        try:
            os.unlink(cfg_tmp)
        except OSError:
            pass
        return False, f"config.json write failed: {e}"
    return True, None


def write_exclude_data(config_path: str, host, database, tables) -> tuple[bool, str | None]:
    """Patch config.hosts[host].databases[database].exclude_data with `tables`
    (replace semantics — the Analyze view sends the full desired set each save).
    An empty list removes the key so the config stays clean, matching how the
    Form view only writes exclude_data when non-empty. The host + database must
    already exist in config; the Analyze pickers only offer configured pairs, so
    a missing one is a real error rather than something to silently create."""
    if not isinstance(host, str) or not IDENT_RE.match(host):
        return False, "host must match the alias shape"
    if not isinstance(database, str) or not IDENT_RE.match(database):
        return False, "database must match the db-name shape"
    if not isinstance(tables, list) or not all(isinstance(t, str) for t in tables):
        return False, "exclude_data must be a list of strings"
    for t in tables:
        # Table names flow into pg_dump --exclude-table-data= / mysqldump
        # --ignore-table=, so constrain them to the same safe shape as db
        # names (IDENT_RE allows a dot for schema-qualified Postgres tables).
        if not IDENT_RE.match(t):
            return False, f"invalid table name: {t!r}"
    cleaned = sorted(set(tables))

    try:
        if os.path.isfile(config_path):
            with open(config_path) as f:
                cfg = json.load(f)
            if not isinstance(cfg, dict):
                return False, "existing config.json is not a JSON object"
        else:
            return False, "config.json not found"
    except (OSError, json.JSONDecodeError) as e:
        return False, f"could not read config.json: {e}"

    hosts = cfg.get("hosts")
    if not isinstance(hosts, dict):
        return False, "hosts block missing or not in object form"
    block = hosts.get(host)
    if not isinstance(block, dict):
        return False, f"host '{host}' not in config"
    dbs = block.get("databases")
    if not isinstance(dbs, dict):
        return False, f"host '{host}' has no databases block"
    db_block = dbs.get(database)
    if not isinstance(db_block, dict):
        return False, f"database '{database}' not configured under host '{host}'"

    if cleaned:
        db_block["exclude_data"] = cleaned
    else:
        db_block.pop("exclude_data", None)

    cfg_tmp = config_path + ".wizard-tmp"
    try:
        with open(cfg_tmp, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        os.chmod(cfg_tmp, 0o600)
        os.replace(cfg_tmp, config_path)
    except OSError as e:
        try:
            os.unlink(cfg_tmp)
        except OSError:
            pass
        return False, f"config.json write failed: {e}"
    return True, None


def run_scrub_subcommand(dbx_bin: str, argv_tail: list,
                         timeout: int = 300) -> tuple[int, str, str]:
    """Run `dbx scrub <argv_tail>` synchronously. init/check are short
    in absolute terms (one schema query + JSON emit), but the schema
    query goes against the *source* host — which can be a prod box on
    the other side of a slow VPN with a 5k-table schema. 5 minutes is
    a generous ceiling for a slow VPN against a large schema; below
    that, internet-distant prod boxes time out spuriously."""
    try:
        result = subprocess.run(
            [dbx_bin, "scrub", *argv_tail],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, (bytes, bytearray)) else (e.stdout or "")
        err = e.stderr.decode("utf-8", "replace") if isinstance(e.stderr, (bytes, bytearray)) else (e.stderr or "")
        return 124, out, err + f"\ntimed out after {timeout}s"


def run_analyze_json(dbx_bin: str, host: str, database: str,
                     no_pii_scan: bool = False,
                     timeout: int = 300) -> tuple[int, str, str]:
    """Run `dbx analyze <host> <database> --json [--no-pii-scan]` and
    return (exit_code, stdout, stderr). Same timeout posture as
    run_scrub_subcommand — the analyze query goes against the *source*
    host which may have thousands of tables behind a slow link. Pass
    no_pii_scan=True to skip the dictionary match (the wizard's Scrub
    tab covers that more thoroughly anyway)."""
    argv = [dbx_bin, "analyze", host, database, "--json"]
    if no_pii_scan:
        argv.append("--no-pii-scan")
    try:
        result = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode("utf-8", "replace") if isinstance(e.stdout, (bytes, bytearray)) else (e.stdout or "")
        err = e.stderr.decode("utf-8", "replace") if isinstance(e.stderr, (bytes, bytearray)) else (e.stderr or "")
        return 124, out, err + f"\ntimed out after {timeout}s"



def list_backups(data_dir: str, config_path: str | None = None):
    """Walk DATA_DIR/<host>/<db>/*.sql.zst[.age|.gpg], read sidecar meta.json.

    Each row carries `safety` — the source host's safety level (prod /
    stage / local). Hosts not in the config or without the field fall
    back to 'local'. Drives the PROD chip / restore-banner UI in the
    wizard without a per-row round-trip.
    """
    out = []
    if not os.path.isdir(data_dir):
        return out
    safety_by_host = _read_host_safety_map(config_path)
    for host in sorted(os.listdir(data_dir)):
        host_dir = os.path.join(data_dir, host)
        if not os.path.isdir(host_dir) or not IDENT_RE.match(host):
            continue
        for db in sorted(os.listdir(host_dir)):
            db_dir = os.path.join(host_dir, db)
            if not os.path.isdir(db_dir) or not IDENT_RE.match(db):
                continue
            for fname in sorted(os.listdir(db_dir), reverse=True):
                if not (fname.endswith(".sql.zst") or fname.endswith(".sql.zst.age")
                        or fname.endswith(".sql.zst.gpg")):
                    continue
                path = os.path.join(db_dir, fname)
                try:
                    stat = os.stat(path)
                except OSError:
                    continue
                meta_path = path + ".meta.json"
                # `complete` = the .meta.json sidecar exists. dbx writes the
                # sidecar AFTER pg_dump / mysqldump returns success (see
                # lib/postgres.sh:159, lib/mysql.sh:193), so a missing sidecar
                # reliably indicates a crashed/orphaned partial backup.
                complete = os.path.isfile(meta_path)
                entry = {
                    "host": host,
                    "database": db,
                    "filename": fname,
                    "path": path,
                    "size": stat.st_size,
                    "mtime": int(stat.st_mtime),
                    "encryption": (
                        "age" if fname.endswith(".age")
                        else "gpg" if fname.endswith(".gpg")
                        else "none"
                    ),
                    "complete": complete,
                    "safety": safety_by_host.get(host, "local"),
                }
                if complete:
                    try:
                        with open(meta_path) as f:
                            meta = json.load(f)
                        for k in ("timestamp", "source_flavor", "source_major_version",
                                  "source_extensions", "dbx_version", "checksums"):
                            if k in meta:
                                entry[k] = meta[k]
                    except (OSError, json.JSONDecodeError):
                        pass
                out.append(entry)
    return out


def _resolve_backup_path(data_dir: str, raw_path):
    """Validate that `raw_path` (arbitrary, from query string or JSON) resolves
    via realpath to a regular `*.sql.zst[.age|.gpg]` file inside DATA_DIR.
    Returns (resolved_path, None) or (None, error).

    Symlinks: realpath resolves them and we still require the resolved path to
    be inside DATA_DIR — so a symlink under DATA_DIR pointing outside is
    correctly rejected."""
    if not isinstance(raw_path, str) or not raw_path:
        return None, "path is required"
    try:
        resolved = os.path.realpath(raw_path)
    except (OSError, ValueError):
        return None, "path could not be resolved"
    data_root = os.path.realpath(data_dir)
    if not (resolved == data_root or resolved.startswith(data_root + os.sep)):
        return None, "path must be inside data-dir"
    if not (resolved.endswith(".sql.zst") or resolved.endswith(".sql.zst.age")
            or resolved.endswith(".sql.zst.gpg")):
        return None, "path must be a .sql.zst[.age|.gpg] backup file"
    if not os.path.isfile(resolved):
        return None, "backup file does not exist"
    return resolved, None


def delete_backup(data_dir: str, raw_path):
    """Remove a backup file and its .meta.json sidecar. The sidecar deletion is
    best-effort (a backup without a sidecar is "incomplete" and we still want
    to clear it). Returns (ok, error_or_None)."""
    resolved, err = _resolve_backup_path(data_dir, raw_path)
    if resolved is None:
        return False, err
    try:
        os.unlink(resolved)
    except OSError as e:
        return False, f"could not delete backup: {e}"
    # Sidecar removal is best-effort — an incomplete backup may not have one.
    meta_path = resolved + ".meta.json"
    if os.path.isfile(meta_path):
        try:
            os.unlink(meta_path)
        except OSError:
            pass
    return True, None


# Allowed audit-log `action` values for filtering. Mirrors the action strings
# emitted by core.sh:audit_log(): backup, restore, scrub_bypass, restore_into,
# vault_set, vault_delete (and vault_get which we expose too for completeness).
# Validated against the URL param to keep this endpoint immune to arbitrary
# string injection (it's only ever JSON-line-parsed, but defense in depth).
AUDIT_ACTION_ALLOWLIST = {
    "backup", "restore", "scrub_bypass", "restore_into",
    "vault_set", "vault_delete", "vault_get",
}

# Allowed `outcome` filter values. audit_log() emits 'success'/'failure', but
# we treat the param as an allowlist so a typo (`?outcome=fail`) is a hard
# 400 instead of silently zero-matching.
AUDIT_OUTCOME_ALLOWLIST = {"success", "failure"}

# Cap regex pattern length. ReDoS protection: a 200-char pattern is plenty
# for "prod.*mysql|error" style queries but bounded enough that Python's
# `re` engine won't catastrophically backtrack on huge crafted patterns.
AUDIT_REGEX_MAX_LEN = 200


def _parse_audit_date_bound(value: str, end_of_day: bool):
    """Parse a `from=` / `to=` URL param into a comparable ISO string.

    Accepts either a full ISO 8601 datetime (e.g. `2026-05-01T10:00:00Z`) or
    a bare `YYYY-MM-DD` date. For bare dates we anchor `from` to 00:00:00Z
    and `to` to 23:59:59Z so the half-open intuition `from <= ts <= to`
    matches what the user clicks in the date picker.

    Returns the comparable string, or None if the value is malformed (caller
    treats None as "filter not applied" so a typo in the URL doesn't 400 —
    the same as how the existing `action=` filter handles missing values).
    Comparison is purely lexicographic because audit_log emits a fixed
    ISO-8601-Z timestamp format, so string compare == time compare.
    """
    if not value:
        return None
    # Bare date: `YYYY-MM-DD`. Treat as inclusive of the whole day.
    if re.match(r"^\d{4}-\d{2}-\d{2}$", value):
        return value + ("T23:59:59Z" if end_of_day else "T00:00:00Z")
    # Full ISO datetime — pass through as-is. We validate shape loosely (must
    # start with YYYY-MM-DD) so junk like `?from=tomorrow` doesn't get used
    # as a filter and instead silently disables it.
    if re.match(r"^\d{4}-\d{2}-\d{2}T", value):
        return value
    return None


def list_audit_log(audit_dir: str, action: str, limit: int,
                   from_ts: str | None = None, to_ts: str | None = None,
                   pattern: "re.Pattern | None" = None,
                   outcome: str | None = None):
    """Return ({"entries": [...], "total": N, "filtered": M}) where entries
    are JSON-parsed audit-log rows, newest first, after applying all filters.

    Filters:
      - action:   exact match on entry["action"] (legacy, allowlisted).
      - from_ts:  entry["timestamp"] >= from_ts (lexicographic ISO compare).
      - to_ts:    entry["timestamp"] <= to_ts.
      - pattern:  pre-compiled regex tested against json.dumps(entry).
      - outcome:  exact match on entry["outcome"] (allowlisted).

    Result fields:
      - total:    well-formed entries in the tail window (before any filter).
      - filtered: entries that survived all filters (before limit truncation).
      - entries:  newest-first, capped at `limit`.

    Performance: the audit log is append-only and grows forever (see
    core.sh:651). We avoid reading the whole file by tailing the last
    `limit * 2` lines via `tail -N`, then parsing + filtering + truncating
    in memory. `limit * 2` is a heuristic: after filtering you may have
    fewer matches than `limit`, so reading 2x gives a reasonable cushion
    without unbounded I/O.

    Returns an empty envelope when the file doesn't exist (not an error:
    the audit log is lazily created on first audited operation).
    """
    audit_path = os.path.join(audit_dir, "audit.log")
    if not os.path.isfile(audit_path):
        return {"entries": [], "total": 0, "filtered": 0}
    # Tail-bounded read: ask `tail` for the last `limit * 2` lines so we
    # have some slack when filtering. Fall back to a Python implementation
    # if tail isn't available (edge case; tail is in coreutils + macOS base).
    tail_lines = max(limit * 2, 50)
    try:
        result = subprocess.run(
            ["tail", "-n", str(tail_lines), audit_path],
            capture_output=True, text=True, timeout=5, check=False,
        )
        raw = result.stdout if result.returncode == 0 else ""
    except (FileNotFoundError, subprocess.TimeoutExpired):
        # Fallback: read the whole file. Acceptable because audit logs
        # are typically <1MB for normal users.
        try:
            with open(audit_path) as f:
                raw = f.read()
        except OSError:
            return {"entries": [], "total": 0, "filtered": 0}

    parsed = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            # Skip malformed lines silently — the audit log is appended
            # under jq so corrupt lines indicate a partial write from a
            # killed process. Don't fail the whole endpoint on one bad row.
            continue
        if not isinstance(entry, dict):
            continue
        parsed.append(entry)

    # `total` is the count of well-formed entries in the tail window, before
    # any filtering. This gives the UI a meaningful "Showing M of N" number
    # for the user's search space (which is the tail, not the whole file).
    total = len(parsed)

    filtered_entries = []
    for entry in parsed:
        if action and entry.get("action") != action:
            continue
        if outcome and entry.get("outcome") != outcome:
            continue
        ts = entry.get("timestamp", "")
        if from_ts and (not isinstance(ts, str) or ts < from_ts):
            continue
        if to_ts and (not isinstance(ts, str) or ts > to_ts):
            continue
        if pattern is not None:
            # Stringify the whole entry so the regex can match any field
            # (host, db, error message, etc.). Sort keys so the haystack is
            # deterministic and the user's regex behaves the same way every
            # call regardless of how core.sh emitted the JSON.
            haystack = json.dumps(entry, sort_keys=True)
            if not pattern.search(haystack):
                continue
        filtered_entries.append(entry)

    filtered_count = len(filtered_entries)
    # Newest first. `tail` already gave us newest at the end; reverse to put
    # newest first, then truncate to `limit`.
    filtered_entries.reverse()
    return {
        "entries": filtered_entries[:limit],
        "total": total,
        "filtered": filtered_count,
    }


def list_containers():
    """Running docker container names — for the --into picker."""
    try:
        result = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        if result.returncode != 0:
            return []
        return [n.strip() for n in result.stdout.splitlines() if n.strip()]
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []


# Managed dev containers (mirrors core.sh:15-16). The diff endpoint resolves
# `source_flavor` -> container name via this map so the UI can tell the user
# which container the diff was inspected against.
_FLAVOR_TO_CONTAINER = {
    "postgres":  "postgres-dbx",
    "mysql":     "mysql-dbx",
    "mariadb":   "mysql-dbx",
}


def resolve_source_to_file(source, data_dir):
    """Resolve a wizard `source` value to (resolved_file, host, database, err).

    Accepts the same two shapes validate_restore_body does:
      - `host/db/latest` or `host/db/<filename>` — looked up under DATA_DIR.
        For `latest`, picks the newest .sql.zst[.age|.gpg] under host/db.
      - A filesystem path inside DATA_DIR — realpath'd and checked.

    Returns (path, host, db, None) on success; (None, None, None, error) on
    failure. host/db are best-effort: for the `host/db/...` shape they come
    straight from the source string; for raw paths we derive them from the
    DATA_DIR-relative directory structure when possible (otherwise empty).
    """
    if not isinstance(source, str) or not source:
        return None, None, None, "source is required"

    m = SOURCE_HOSTDB_RE.match(source)
    if m:
        host, db, selector = m.group(1), m.group(2), m.group(3)
        backup_dir = os.path.join(data_dir, host, db)
        if not os.path.isdir(backup_dir):
            return None, None, None, f"no backups found for {host}/{db}"
        if selector == "latest":
            # Newest .sql.zst[.age|.gpg] under host/db. Sorted by mtime desc.
            candidates = []
            for fname in os.listdir(backup_dir):
                if not (fname.endswith(".sql.zst")
                        or fname.endswith(".sql.zst.age")
                        or fname.endswith(".sql.zst.gpg")):
                    continue
                fpath = os.path.join(backup_dir, fname)
                try:
                    candidates.append((os.stat(fpath).st_mtime, fpath))
                except OSError:
                    continue
            if not candidates:
                return None, None, None, f"no backups found for {host}/{db}"
            candidates.sort(reverse=True)
            return candidates[0][1], host, db, None
        # Specific filename.
        path = os.path.join(backup_dir, selector)
        if not os.path.isfile(path):
            return None, None, None, "source file does not exist"
        return path, host, db, None

    # Raw path. Same checks as validate_restore_body.
    try:
        resolved = os.path.realpath(source)
    except (OSError, ValueError):
        return None, None, None, "source path could not be resolved"
    data_root = os.path.realpath(data_dir)
    if not (resolved == data_root or resolved.startswith(data_root + os.sep)):
        return None, None, None, "source must be inside data-dir or use host/db/latest shape"
    if not os.path.isfile(resolved):
        return None, None, None, "source file does not exist"
    if not (resolved.endswith(".sql.zst") or resolved.endswith(".sql.zst.age")
            or resolved.endswith(".sql.zst.gpg")):
        return None, None, None, "source must be a .sql.zst[.age|.gpg] backup file"
    # Derive host/db from the DATA_DIR-relative directory: <root>/<host>/<db>/<file>.
    rel = resolved[len(data_root) + 1:] if resolved.startswith(data_root + os.sep) else ""
    parts = rel.split(os.sep)
    host = parts[0] if len(parts) >= 3 else ""
    db = parts[1] if len(parts) >= 3 else ""
    return resolved, host, db, None


def _read_meta_for_backup(backup_path):
    """Read the sidecar .meta.json next to a backup file. Returns {} when the
    sidecar is missing or unparseable — callers treat empty meta as
    'source details unknown' rather than failing the request."""
    if not backup_path:
        return {}
    meta_path = backup_path + ".meta.json"
    if not os.path.isfile(meta_path):
        return {}
    try:
        with open(meta_path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _list_target_tables(container, target_name, flavor):
    """Inspect the dev container for the target db's tables.

    Returns (target_exists, tables_list). Failures (no docker / no container /
    target db doesn't exist) all degrade silently to (False, []) so the diff
    endpoint stays informative without docker — tests run without docker.

    Capped at 200 tables to bound the response size.
    """
    if not container or not target_name:
        return False, []
    flavor = (flavor or "").lower()
    try:
        if flavor == "postgres":
            # Check existence: `psql -lqt` lists databases, one per line, with
            # the name in column 1. Use `-tA` for a clean parseable form.
            existence = subprocess.run(
                ["docker", "exec", container, "psql", "-U", "postgres",
                 "-tAc", "SELECT datname FROM pg_database;"],
                capture_output=True, text=True, timeout=5, check=False,
            )
            if existence.returncode != 0:
                return False, []
            dbs = {ln.strip() for ln in existence.stdout.splitlines() if ln.strip()}
            if target_name not in dbs:
                return False, []
            # Target exists — list tables (public schema only, matches what
            # pg_dump emits for a typical user db).
            tables = subprocess.run(
                ["docker", "exec", container, "psql", "-U", "postgres",
                 "-d", target_name, "-tAc",
                 "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;"],
                capture_output=True, text=True, timeout=5, check=False,
            )
            if tables.returncode != 0:
                return True, []
            names = [ln.strip() for ln in tables.stdout.splitlines() if ln.strip()]
            return True, names[:200]
        if flavor in ("mysql", "mariadb"):
            existence = subprocess.run(
                ["docker", "exec", container, "mysql", "-N", "-B", "-e",
                 "SHOW DATABASES;"],
                capture_output=True, text=True, timeout=5, check=False,
            )
            if existence.returncode != 0:
                return False, []
            dbs = {ln.strip() for ln in existence.stdout.splitlines() if ln.strip()}
            if target_name not in dbs:
                return False, []
            tables = subprocess.run(
                ["docker", "exec", container, "mysql", "-N", "-B", "-e",
                 f"SHOW TABLES FROM `{target_name}`;"],
                capture_output=True, text=True, timeout=5, check=False,
            )
            if tables.returncode != 0:
                return True, []
            names = [ln.strip() for ln in tables.stdout.splitlines() if ln.strip()]
            return True, names[:200]
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False, []
    return False, []


def compute_restore_diff(source, target_name, data_dir, config_path):
    """Build the response payload for GET /api/restore/diff.

    Returns (payload, error_or_None). Validates source + target_name, resolves
    source to a backup file, reads its sidecar meta.json for flavor/safety,
    and asks docker whether the target db exists in the canonical managed
    container. Docker failures (no docker, no container, no target db) all
    degrade to a "target will be CREATED" response — never 5xx.
    """
    # Target name shape — strict so a typo like `;DROP DATABASE` is a 400 not
    # a docker-exec attempt.
    if not isinstance(target_name, str) or not target_name:
        return None, "target is required"
    if not NAME_RE.match(target_name):
        return None, "target must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}"

    resolved, host, db, err = resolve_source_to_file(source, data_dir)
    if err is not None:
        return None, err
    assert resolved is not None

    meta = _read_meta_for_backup(resolved)
    safety_by_host = _read_host_safety_map(config_path)
    flavor = str(meta.get("source_flavor", "")).lower()
    container = _FLAVOR_TO_CONTAINER.get(flavor, "")

    target_exists, target_tables = _list_target_tables(container, target_name, flavor)

    src_size = None
    try:
        src_size = os.stat(resolved).st_size
    except OSError:
        pass

    src_payload = {
        "host": host or "",
        "database": db or "",
        "filename": os.path.basename(resolved),
        "path": resolved,
        "timestamp": meta.get("timestamp", ""),
        "size_bytes": src_size,
        "source_flavor": meta.get("source_flavor", ""),
        "source_major_version": meta.get("source_major_version", ""),
        "safety": safety_by_host.get(host, "local") if host else "local",
    }

    target_payload = {
        "container": container,
        "name": target_name,
        "table_count": len(target_tables) if target_exists else 0,
        "tables": target_tables if target_exists else [],
    }

    if not target_exists:
        diff_summary = f"Target db `{target_name}` will be CREATED."
        if container:
            diff_summary += f" (no existing db named `{target_name}` in `{container}`)"
        else:
            diff_summary += " (source flavor unknown — container could not be inspected)"
    else:
        # We don't know source table count (would require opening the
        # backup), so the summary just reports the destination side.
        diff_summary = (
            f"Target db `{target_name}` exists in `{container}` with "
            f"{len(target_tables)} table(s); restore will DROP + recreate it."
        )

    return {
        "target_exists": target_exists,
        "source": src_payload,
        "target": target_payload,
        "diff_summary": diff_summary,
    }, None


def read_schedule_state(lib_dir: str, config_path: str, data_dir: str, audit_dir: str, now=None):
    """Source core.sh + schedule.sh in a bash subprocess and read all three
    TSV blocks (declarative / installed / sync plan). Declarative rows are
    enriched with `next_at` (computed next fire time) and `last_run` (newest
    backup outcome for the pair, from the audit log). Returns a dict suitable
    for JSON response, or raises RuntimeError on shell failure."""
    script = r"""
set -e
. "$LIB_DIR/core.sh"
. "$LIB_DIR/schedule.sh"
CFG=$(schedule_config_read || true)
INST=$(schedule_installed_read || true)
PLAN=$(schedule_sync_plan "$CFG" "$INST")
printf '__CFG__\n%s\n__INST__\n%s\n__PLAN__\n%s\n__END__\n' "$CFG" "$INST" "$PLAN"
"""
    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "LIB_DIR": lib_dir,
        "DBX_CONFIG_DIR": os.path.dirname(config_path),
        "DBX_DATA_DIR": data_dir,
    }
    try:
        result = subprocess.run(
            ["bash", "-c", script], env=env,
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"bash invocation failed: {e}") from e
    if result.returncode != 0:
        raise RuntimeError(f"schedule helpers failed: {result.stderr.strip() or result.stdout.strip()}")

    # Split on the three sentinel markers; each block is multiline TSV.
    out = result.stdout
    sections = {"__CFG__": "", "__INST__": "", "__PLAN__": ""}
    current = None
    for line in out.splitlines():
        if line in sections:
            current = line
            continue
        if line == "__END__":
            current = None
            continue
        if current is not None:
            sections[current] += line + "\n"

    def parse_tsv_rows(blob: str, columns: list):
        rows = []
        for line in blob.splitlines():
            if not line.strip():
                continue
            parts = line.split("\t")
            row = {columns[i]: (parts[i] if i < len(parts) else "") for i in range(len(columns))}
            rows.append(row)
        return rows

    # Source the declarative list straight from config.json (full fidelity:
    # includes disabled rows + enabled/keep), since schedule_config_read now
    # filters disabled rows out for the sync side.
    declarative = [dict(s) for s in _read_schedules_block(config_path) if isinstance(s, dict)]

    # Enrich declarative rows so the Schedule view shows real "Next run" /
    # "Last run" instead of placeholders: next_at is computed from the `when`
    # expression; last_run is the newest backup outcome for the pair.
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    last_by_pair = {}
    for entry in _read_audit_log_full(audit_dir):
        if entry.get("action") != "backup":
            continue
        h, d = entry.get("db_host"), entry.get("database")
        outcome = entry.get("outcome")
        ts = _parse_iso8601_utc(entry.get("timestamp"))
        if not isinstance(h, str) or not isinstance(d, str) or ts is None:
            continue
        if outcome not in ("success", "failure"):
            continue
        cur = last_by_pair.get((h, d))
        if cur is None or ts > cur[0]:
            last_by_pair[(h, d)] = (ts, outcome)
    for row in declarative:
        nxt = _compute_next_schedule_fire(row.get("when"), now)
        row["next_at"] = nxt.strftime("%Y-%m-%dT%H:%M:%SZ") if nxt else None
        lr = last_by_pair.get((row.get("host"), row.get("database")))
        row["last_run"] = (
            {"outcome": lr[1], "timestamp": lr[0].strftime("%Y-%m-%dT%H:%M:%SZ")}
            if lr else None
        )

    return {
        "declarative": declarative,
        "installed":   parse_tsv_rows(sections["__INST__"], ["host", "database", "when"]),
        "plan":        parse_tsv_rows(sections["__PLAN__"], ["action", "host", "database", "when"]),
    }


def write_schedules_block(config_path: str, schedules):
    """Validate and write the schedules[] block into the existing config.json,
    preserving every other key. Returns (ok, error_message). `schedules` is
    deliberately untyped — it comes from arbitrary JSON and may not be a list."""
    if not isinstance(schedules, list):
        return False, "schedules must be a JSON array"
    if len(schedules) > 1000:
        return False, "too many schedules (>1000)"

    cleaned = []
    for i, s in enumerate(schedules):
        if not isinstance(s, dict):
            return False, f"schedules[{i}] must be an object"
        host = s.get("host")
        database = s.get("database")
        when = s.get("when")
        if not isinstance(host, str) or not IDENT_RE.match(host):
            return False, f"schedules[{i}].host must match the host-alias shape"
        if not isinstance(database, str) or not IDENT_RE.match(database):
            return False, f"schedules[{i}].database must match the db-name shape"
        if not isinstance(when, str) or not (1 <= len(when) <= 128):
            return False, f"schedules[{i}].when must be a string (1-128 chars)"
        row: dict = {"host": host, "database": database, "when": when}
        # enabled: persist only when explicitly disabled (absent == enabled),
        # so configs that never used the field stay byte-identical.
        enabled = s.get("enabled")
        if enabled is False:
            row["enabled"] = False
        elif enabled not in (None, True):
            return False, f"schedules[{i}].enabled must be a boolean"
        # keep: optional positive retention count applied by `schedule run-job`.
        keep = s.get("keep")
        if keep not in (None, ""):
            if not isinstance(keep, int) or isinstance(keep, bool) or keep < 1 or keep > 100000:
                return False, f"schedules[{i}].keep must be a positive integer"
            row["keep"] = keep
        cleaned.append(row)

    # Read existing config, replace schedules block, write back atomically.
    try:
        if os.path.isfile(config_path):
            with open(config_path) as f:
                config = json.load(f)
            if not isinstance(config, dict):
                return False, "existing config.json is not a JSON object"
        else:
            config = {}
    except (OSError, json.JSONDecodeError) as e:
        return False, f"could not read existing config.json: {e}"

    config["schedules"] = cleaned

    tmp_path = config_path + ".wizard-tmp"
    try:
        os.makedirs(os.path.dirname(config_path), exist_ok=True)
        with open(tmp_path, "w") as f:
            json.dump(config, f, indent=2)
            f.write("\n")
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, config_path)
    except OSError as e:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        return False, f"write failed: {e}"

    return True, None


def _parse_iso8601_utc(ts):
    """Parse an ISO 8601 timestamp with a trailing 'Z' (the audit_log format)
    into a timezone-aware UTC datetime. Returns None if the string can't be
    parsed — callers treat a None as "no successful/failed run seen yet"
    rather than failing the whole dashboard render."""
    if not isinstance(ts, str) or not ts:
        return None
    # `datetime.fromisoformat` accepts the "+00:00" form natively; rewrite
    # the trailing Z. This avoids pulling in dateutil for one timestamp shape.
    s = ts.replace("Z", "+00:00") if ts.endswith("Z") else ts
    try:
        dt = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def _compute_next_schedule_fire(when, now):
    """Return the next ISO 8601 UTC timestamp this schedule expression should
    fire at, given the current time. Mirrors lib/schedule.sh:parse_schedule's
    grammar (hourly | daily[@H] | weekly[@D:H] | raw cron). For raw cron we
    return tomorrow at 00:00 UTC — the v1 goal is "show the user something
    plausible" rather than full cron evaluation. Returns None if `when` is
    not a recognisable shape."""
    if not isinstance(when, str) or not when:
        return None

    s = when.strip()
    # `now` is timezone-aware UTC; align all comparisons there.

    def at(year, month, day, hour, minute=0):
        return datetime.datetime(
            year, month, day, hour, minute, 0, tzinfo=datetime.timezone.utc
        )

    if s == "hourly":
        # Next top of the hour.
        nxt = now.replace(minute=0, second=0, microsecond=0) + datetime.timedelta(hours=1)
        return nxt

    if s == "daily" or s.startswith("daily@"):
        hour = 2
        if s.startswith("daily@"):
            tail = s[len("daily@"):]
            try:
                hour = int(tail)
            except ValueError:
                return None
            if not (0 <= hour <= 23):
                return None
        today = at(now.year, now.month, now.day, hour)
        if today <= now:
            today = today + datetime.timedelta(days=1)
        return today

    if s == "weekly" or s.startswith("weekly@"):
        day = 0
        hour = 2
        if s.startswith("weekly@"):
            tail = s[len("weekly@"):]
            # weekly@<D>:<H> — D is 0..6 (Sun..Sat) per parse_schedule's docstring.
            if ":" not in tail:
                return None
            d_str, _, h_str = tail.partition(":")
            try:
                day = int(d_str)
                hour = int(h_str)
            except ValueError:
                return None
            if not (0 <= day <= 6) or not (0 <= hour <= 23):
                return None
        # Python's weekday(): Monday=0..Sunday=6. cron's: Sunday=0..Saturday=6.
        # Map cron-D → Python weekday: Sun(0)→6, Mon(1)→0, ..., Sat(6)→5.
        py_weekday = (day + 6) % 7
        candidate = at(now.year, now.month, now.day, hour)
        delta_days = (py_weekday - now.weekday()) % 7
        candidate = candidate + datetime.timedelta(days=delta_days)
        if candidate <= now:
            candidate = candidate + datetime.timedelta(days=7)
        return candidate

    # Raw cron expression — return tomorrow at midnight as a "you have
    # something scheduled" placeholder. Better than null; honest about
    # being approximate.
    tomorrow = (now + datetime.timedelta(days=1)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return tomorrow


def _read_audit_log_full(audit_dir):
    """Read every line of audit.log, parse, return list of dicts (oldest
    first). Returns [] if the file's missing. Used by the dashboard, which
    needs all-time per-pair last_success/last_failure, not just a tail."""
    audit_path = os.path.join(audit_dir, "audit.log")
    if not os.path.isfile(audit_path):
        return []
    try:
        with open(audit_path) as f:
            raw = f.read()
    except OSError:
        return []
    entries = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(entry, dict):
            entries.append(entry)
    return entries


def _read_schedules_block(config_path):
    """Return the schedules[] array from config.json (or []). Tolerant of
    missing/malformed config so the dashboard can still render."""
    if not config_path or not os.path.isfile(config_path):
        return []
    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(cfg, dict):
        return []
    schedules = cfg.get("schedules", [])
    if not isinstance(schedules, list):
        return []
    return schedules


def _compute_trends(audit_entries, now, weeks=8):
    """Backups-per-week and bytes-backed-up-per-week for the last `weeks` weeks
    (oldest first), from successful backup events in the audit log. On-disk
    storage history isn't tracked, so these reflect backup *activity* over time,
    not current disk usage (which the summary already reports)."""
    counts = [0] * weeks
    sizes = [0] * weeks
    for entry in audit_entries:
        if entry.get("action") != "backup" or entry.get("outcome") != "success":
            continue
        ts = _parse_iso8601_utc(entry.get("timestamp"))
        if ts is None:
            continue
        weeks_ago = int((now - ts).total_seconds() // (7 * 86400))
        if weeks_ago < 0 or weeks_ago >= weeks:
            continue
        idx = (weeks - 1) - weeks_ago
        counts[idx] += 1
        sizes[idx] += _coerce_int(entry.get("size")) or 0
    out = []
    for i in range(weeks):
        label = (now - datetime.timedelta(weeks=(weeks - 1) - i)).strftime("%b %d")
        out.append({"label": label, "backups": counts[i], "bytes": sizes[i]})
    return out


def compute_dashboard(data_dir, audit_dir, config_path, now=None):
    """Compose the dashboard payload from DATA_DIR + audit.log + schedules[].

    Walks DATA_DIR for host/db pairs that have at least one backup file;
    finds the most recent success and most recent failure for each from the
    audit log; matches schedules; computes a status bucket from the most
    recent backup's age (fresh <24h, aging <7d, else stale).

    Sort: stale → aging → fresh (broken first). Within a bucket, oldest-
    backup first so the user sees the worst-off pairs at the top of each
    bucket.

    Pass `now` (timezone-aware UTC) for test determinism."""
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)

    # 1. Enumerate host/db pairs that have actual backup files on disk.
    pairs = {}   # (host, db) -> {newest_file: dict, total_bytes: int, count: int}
    if os.path.isdir(data_dir):
        for host in sorted(os.listdir(data_dir)):
            host_dir = os.path.join(data_dir, host)
            if not os.path.isdir(host_dir) or not IDENT_RE.match(host):
                continue
            for db in sorted(os.listdir(host_dir)):
                db_dir = os.path.join(host_dir, db)
                if not os.path.isdir(db_dir) or not IDENT_RE.match(db):
                    continue
                newest = None
                total_bytes = 0
                count = 0
                for fname in os.listdir(db_dir):
                    if not (fname.endswith(".sql.zst")
                            or fname.endswith(".sql.zst.age")
                            or fname.endswith(".sql.zst.gpg")):
                        continue
                    path = os.path.join(db_dir, fname)
                    try:
                        stat = os.stat(path)
                    except OSError:
                        continue
                    count += 1
                    total_bytes += stat.st_size
                    if newest is None or stat.st_mtime > newest["mtime"]:
                        newest = {
                            "file": path,
                            "filename": fname,
                            "mtime": stat.st_mtime,
                            "size": stat.st_size,
                        }
                if newest is not None:
                    pairs[(host, db)] = {
                        "newest": newest,
                        "total_bytes": total_bytes,
                        "count": count,
                    }

    # 2. Walk audit.log once and index newest success + newest failure per pair.
    audit_entries = _read_audit_log_full(audit_dir)
    last_success = {}   # (host, db) -> entry
    last_failure = {}
    for entry in audit_entries:
        if entry.get("action") != "backup":
            continue
        host = entry.get("db_host")
        db = entry.get("database")
        if not isinstance(host, str) or not isinstance(db, str):
            continue
        key = (host, db)
        ts = _parse_iso8601_utc(entry.get("timestamp"))
        if ts is None:
            continue
        outcome = entry.get("outcome")
        bucket = last_success if outcome == "success" else last_failure if outcome == "failure" else None
        if bucket is None:
            continue
        existing = bucket.get(key)
        if existing is None or ts > existing[0]:
            bucket[key] = (ts, entry)

    # 3. Schedules[] from config.json, indexed by (host, db) → when.
    schedules = _read_schedules_block(config_path)
    sched_by_pair = {}
    for s in schedules:
        if not isinstance(s, dict):
            continue
        h = s.get("host")
        d = s.get("database")
        w = s.get("when")
        if isinstance(h, str) and isinstance(d, str) and isinstance(w, str):
            sched_by_pair[(h, d)] = w

    # 4. Build the per-pair card payload.
    cards = []
    for (host, db), info in pairs.items():
        newest = info["newest"]
        newest_ts = datetime.datetime.fromtimestamp(
            newest["mtime"], tz=datetime.timezone.utc
        )

        # Prefer the audit-log success row for last_success (it carries the
        # original ISO 8601 timestamp + size) but fall back to filesystem
        # mtime when no audit entry exists. Either way `age_seconds` drives
        # the status chip.
        success_entry = last_success.get((host, db))
        if success_entry is not None:
            ts_dt, audit_row = success_entry
            age_sec = int((now - ts_dt).total_seconds())
            last_success_payload = {
                "timestamp": ts_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "age_seconds": max(0, age_sec),
                "size": _coerce_int(audit_row.get("size")),
                "file": audit_row.get("file") or newest["file"],
            }
        else:
            age_sec = int((now - newest_ts).total_seconds())
            last_success_payload = {
                "timestamp": newest_ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "age_seconds": max(0, age_sec),
                "size": newest["size"],
                "file": newest["file"],
            }

        # Status from age of most recent SUCCESS we can attest to.
        if age_sec < 86400:
            status = "fresh"
        elif age_sec < 86400 * 7:
            status = "aging"
        else:
            status = "stale"

        # Failure → expose the error field if the audit row carried one.
        # audit_backup() doesn't write `error` today but failures may, and
        # the spec asks us to surface it when present.
        failure_entry = last_failure.get((host, db))
        if failure_entry is not None:
            f_ts, f_row = failure_entry
            last_failure_payload = {
                "timestamp": f_ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "error": f_row.get("error") or "",
            }
        else:
            last_failure_payload = None

        when_expr = sched_by_pair.get((host, db))
        if when_expr:
            next_at = _compute_next_schedule_fire(when_expr, now)
            next_scheduled_payload = {
                "when": when_expr,
                "next_at": next_at.strftime("%Y-%m-%dT%H:%M:%SZ") if next_at else None,
            }
        else:
            next_scheduled_payload = None

        cards.append({
            "host": host,
            "database": db,
            "last_success": last_success_payload,
            "last_failure": last_failure_payload,
            "next_scheduled": next_scheduled_payload,
            "status": status,
        })

    # 5. Sort: stale → aging → fresh, then oldest-backup first inside each
    # bucket (highest risk first), then host/db alphabetic as a stable
    # tiebreak. Negating age_seconds gives descending age within a bucket.
    status_rank = {"stale": 0, "aging": 1, "fresh": 2}
    cards.sort(key=lambda c: (
        status_rank.get(c["status"], 99),
        -c["last_success"]["age_seconds"],
        c["host"], c["database"],
    ))

    # 6. Top-line summary strip.
    total_backups = sum(p["count"] for p in pairs.values())
    total_bytes = sum(p["total_bytes"] for p in pairs.values())
    hosts = len({host for (host, _) in pairs})
    databases = len(pairs)
    fresh = sum(1 for c in cards if c["status"] == "fresh")
    aging = sum(1 for c in cards if c["status"] == "aging")
    stale = sum(1 for c in cards if c["status"] == "stale")

    return {
        "summary": {
            "total_backups": total_backups,
            "total_bytes": total_bytes,
            "hosts": hosts,
            "databases": databases,
            "fresh": fresh,
            "aging": aging,
            "stale": stale,
        },
        "cards": cards,
        "trends": _compute_trends(audit_entries, now),
    }


def _enumerate_backup_files(data_dir):
    """Yield every backup file under DATA_DIR as (host, db, path, stat).

    Shared by the storage usage + clean-preview endpoints. Mirrors the walk
    in `cmd_clean` (lib/core.sh): host_dir / db_dir / *.sql.zst[.age|.gpg],
    skipping sidecars and non-backup files. Both host and db identifiers
    are filtered through IDENT_RE so a stray dotfile or symlinked junk
    doesn't sneak into the totals.

    The caller decides whether to group by pair, sort by mtime, etc. — this
    helper just emits files in a stable host/db/filename order.
    """
    if not os.path.isdir(data_dir):
        return
    for host in sorted(os.listdir(data_dir)):
        host_dir = os.path.join(data_dir, host)
        if not os.path.isdir(host_dir) or not IDENT_RE.match(host):
            continue
        for db in sorted(os.listdir(host_dir)):
            db_dir = os.path.join(host_dir, db)
            if not os.path.isdir(db_dir) or not IDENT_RE.match(db):
                continue
            for fname in sorted(os.listdir(db_dir)):
                if not (fname.endswith(".sql.zst")
                        or fname.endswith(".sql.zst.age")
                        or fname.endswith(".sql.zst.gpg")):
                    continue
                path = os.path.join(db_dir, fname)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                yield host, db, path, st


def _sidecar_bytes(path):
    """Return the size of `<path>.meta.json` if it exists, else 0. Sidecar
    bytes count toward `reclaim_bytes` (the user is freeing them too) but
    NOT toward `reclaim_count` (those are user-facing backup files)."""
    meta = path + ".meta.json"
    try:
        return os.path.getsize(meta)
    except OSError:
        return 0


def compute_storage_usage(data_dir):
    """Composed payload for `GET /api/storage/usage`.

    Walks DATA_DIR, builds a per host/db table with per-pair totals + the
    largest / oldest / newest backup, and a global summary. Also reports
    the free space on DATA_DIR's filesystem (statvfs) so the UI can render
    a "used / free" disk bar at the top of the view.

    `free_bytes` is null when statvfs fails (e.g. DATA_DIR doesn't exist on
    disk yet). The rest of the payload still degrades cleanly to empty.
    """
    # Per-pair accumulator. Each entry tracks count + total + biggest +
    # oldest + newest so the UI can show all the useful columns in one
    # round-trip without re-walking the tree client-side.
    by_pair_map: dict = {}
    total_bytes = 0
    total_files = 0
    for host, db, path, st in _enumerate_backup_files(data_dir):
        key = (host, db)
        entry = by_pair_map.get(key)
        size = st.st_size
        mtime = st.st_mtime
        if entry is None:
            entry = {
                "host": host,
                "database": db,
                "count": 0,
                "bytes": 0,
                "largest_bytes": 0,
                "oldest_mtime": mtime,
                "newest_mtime": mtime,
            }
            by_pair_map[key] = entry
        entry["count"] += 1
        entry["bytes"] += size
        if size > entry["largest_bytes"]:
            entry["largest_bytes"] = size
        if mtime < entry["oldest_mtime"]:
            entry["oldest_mtime"] = mtime
        if mtime > entry["newest_mtime"]:
            entry["newest_mtime"] = mtime
        total_bytes += size
        total_files += 1

    by_pair = []
    for entry in by_pair_map.values():
        oldest_dt = datetime.datetime.fromtimestamp(
            entry.pop("oldest_mtime"), tz=datetime.timezone.utc
        )
        newest_dt = datetime.datetime.fromtimestamp(
            entry.pop("newest_mtime"), tz=datetime.timezone.utc
        )
        entry["oldest_iso"] = oldest_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        entry["newest_iso"] = newest_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        by_pair.append(entry)
    # Sort by bytes descending; tie-break alphabetically so the table is
    # stable across reloads.
    by_pair.sort(key=lambda r: (-r["bytes"], r["host"], r["database"]))

    # statvfs needs a path that exists; fall back to the closest existing
    # ancestor so a freshly-installed setup with no DATA_DIR still reports
    # plausible disk free space.
    free_bytes = None
    probe = data_dir
    while probe and not os.path.exists(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    if probe and os.path.exists(probe):
        try:
            stv = os.statvfs(probe)
            free_bytes = stv.f_bavail * stv.f_frsize
        except (OSError, AttributeError):
            free_bytes = None

    return {
        "total_bytes": total_bytes,
        "total_files": total_files,
        "free_bytes": free_bytes,
        "by_pair": by_pair,
    }


def compute_clean_preview(data_dir, keep, older_than, now=None):
    """Mirror the bash `cmd_clean` selection logic and return the files that
    would be deleted. Both `keep` and `older_than` may be None; the caller
    enforces "at least one must be set". When both are set, the result is
    the UNION of marked files (matches the bash side, which evaluates both
    conditions independently and removes anything that matches either).

    The bash side's mutually-exclusive-modes behaviour (#22) is subtly
    different: passing both flags treats `--keep` as a floor inside age
    mode. For the wizard preview we keep the union semantics so the UI is
    predictable — the underlying `dbx clean` invocation we spawn for the
    real run uses whichever single flag the user actually selected.

    Returns `(would_delete, reclaim_bytes, reclaim_count)`. Sidecar
    `.meta.json` bytes are folded into `reclaim_bytes` but the sidecars
    themselves are NOT in `would_delete` and don't bump `reclaim_count`.
    """
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()

    # Group files by pair, sorted newest-first (mtime descending). cmd_clean
    # uses `ls -t`; we replicate that with explicit sort. Each entry is a
    # dict so we can carry the size + sidecar info into the preview output.
    by_pair: dict = {}
    for host, db, path, st in _enumerate_backup_files(data_dir):
        by_pair.setdefault((host, db), []).append({
            "path": path,
            "host": host,
            "database": db,
            "bytes": st.st_size,
            "mtime": st.st_mtime,
        })

    marked: dict = {}   # path -> entry, used as a set with insertion order
    for entries in by_pair.values():
        entries.sort(key=lambda e: -e["mtime"])
        if keep is not None and len(entries) > keep:
            # Same as bash: backups[keep:] are removed (newest `keep` are
            # preserved at the head of the list).
            for e in entries[keep:]:
                marked[e["path"]] = e
        if older_than is not None:
            cutoff = now - older_than * 86400
            for e in entries:
                if e["mtime"] < cutoff:
                    marked[e["path"]] = e

    would_delete = []
    reclaim_bytes = 0
    for e in marked.values():
        sidecar = _sidecar_bytes(e["path"])
        reclaim_bytes += e["bytes"] + sidecar
        ts = datetime.datetime.fromtimestamp(
            e["mtime"], tz=datetime.timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        would_delete.append({
            "path": e["path"],
            "host": e["host"],
            "database": e["database"],
            "bytes": e["bytes"],
            "timestamp": ts,
        })

    # Sort by mtime descending isn't user-friendly (newest-first removed
    # files mixed across hosts); sort by host/db/timestamp so the user can
    # scan the list and the largest pairs appear together.
    would_delete.sort(key=lambda r: (r["host"], r["database"], r["timestamp"]))

    return would_delete, reclaim_bytes, len(would_delete)


def _coerce_int(v):
    """audit_log writes everything as strings (jq --arg), so size/duration
    arrive as numeric strings. Coerce to int when possible; pass null
    through; return null for un-coercible strings."""
    if v is None or v == "":
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


# Map dbx's internal backend names to the human-facing labels surfaced in
# the Vault view + JSON payload. Anything else passes through verbatim.
_BACKEND_LABELS = {
    "keychain": "macos-keychain",
    "secret-tool": "libsecret",
    "pass": "pass",
    "gpg-file": "gpg",
    "none": "none",
}


def _detect_vault_backend(dbx_bin):
    """Shell out to `dbx vault info` and parse the first 'Vault backend:' line.
    Returns the human label (`macos-keychain` / `libsecret` / `gpg` / `pass`
    / `none`) or `'unknown'` on failure. Single backend invocation per
    /api/vault/list call — all rows share the same backend."""
    try:
        result = subprocess.run(
            [dbx_bin, "vault", "info"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return "unknown"
    if result.returncode != 0:
        return "unknown"
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.lower().startswith("vault backend:"):
            raw = line.split(":", 1)[1].strip()
            return _BACKEND_LABELS.get(raw, raw or "unknown")
    return "unknown"


def _list_vault_keys(dbx_bin):
    """Shell out to `dbx vault list` and parse the indented account lines.
    The CLI format (lib/encrypt.sh + dbx:cmd_vault) is:

        Stored credentials:
          key1
          key2
          (none)

    Plus an optional 'Encryption:' / 'Key is set' tail block for the
    encryption-key marker, which we suppress. Returns [] when no keys
    are stored or the command fails."""
    try:
        result = subprocess.run(
            [dbx_bin, "vault", "list"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return []
    if result.returncode != 0:
        return []
    keys = []
    in_creds = False
    for raw in result.stdout.splitlines():
        line = raw.rstrip()
        # Strip ANSI escape sequences (BOLD/NC) that cmd_vault prints
        # around the section header. Strict-printable filter keeps the
        # parse simple and robust.
        cleaned = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
        if not cleaned:
            continue
        # Section markers. We only collect inside the 'Stored credentials:'
        # block; the 'Encryption:' block lists the encryption key marker
        # which is internal-only and should not appear in the wizard.
        if cleaned.lower().startswith("stored credentials"):
            in_creds = True
            continue
        if cleaned.lower().startswith("encryption"):
            in_creds = False
            continue
        if not in_creds:
            continue
        # "(none)" sentinel means the list is empty. Other lines are
        # accounts; cmd_vault already filtered out _dbx_encryption_key.
        if cleaned == "(none)":
            continue
        if VAULT_KEY_RE.match(cleaned):
            keys.append(cleaned)
    return keys


def _vault_last_set_map(audit_dir):
    """Walk audit.log and return {account: most_recent_vault_set_timestamp}.
    Only `vault_set` rows with outcome=success contribute. Returns {} when
    the file is missing or unreadable — callers fall back to `null`."""
    entries = _read_audit_log_full(audit_dir)
    out = {}
    for entry in entries:
        if entry.get("action") != "vault_set":
            continue
        if entry.get("outcome") != "success":
            continue
        account = entry.get("account")
        ts = entry.get("timestamp")
        if not isinstance(account, str) or not isinstance(ts, str):
            continue
        # Newest wins. Timestamps are ISO 8601 Z strings — string compare
        # is correct for that format.
        prev = out.get(account)
        if prev is None or ts > prev:
            out[account] = ts
    return out


def _age_recipients_path():
    """Return the path to the age recipients file, matching lib/encrypt.sh:13:
    `${DBX_AGE_RECIPIENTS:-$CONFIG_DIR/age-recipients.txt}`. We honor the
    DBX_AGE_RECIPIENTS env var so tests can sandbox the path under
    BATS_TEST_TMPDIR."""
    override = os.environ.get("DBX_AGE_RECIPIENTS")
    if override:
        return override
    # CONFIG_DIR mirrors core.sh: $DBX_CONFIG_DIR ?: $HOME/.config/dbx.
    config_dir = os.environ.get("DBX_CONFIG_DIR")
    if not config_dir:
        config_dir = os.path.join(os.environ.get("HOME", ""), ".config", "dbx")
    return os.path.join(config_dir, "age-recipients.txt")


def _read_age_recipients(path):
    """Return (recipients, error). recipients is a list of non-comment,
    non-blank lines from the file; comments (lines starting with #) are
    silently dropped at read time but preserved on write."""
    if not os.path.isfile(path):
        return [], None
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError as e:
        return [], str(e)
    out = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        out.append(stripped)
    return out, None


def _write_age_recipients_atomic(path, lines):
    """Atomic write: tmp file + os.replace, 0600 permissions. Caller is
    responsible for assembling `lines` — we just persist them as-is."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    except OSError as e:
        return False, f"could not create config dir: {e}"
    tmp_path = path + ".wizard-tmp"
    try:
        with open(tmp_path, "w") as f:
            for line in lines:
                f.write(line)
                if not line.endswith("\n"):
                    f.write("\n")
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, path)
    except OSError as e:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        return False, f"write failed: {e}"
    return True, None


def _add_age_recipient(path, recipient):
    """Append `recipient` to the recipients file if not already present.
    Preserves comments + blank lines. Returns (ok, error_or_None)."""
    existing_lines = []
    if os.path.isfile(path):
        try:
            with open(path) as f:
                existing_lines = f.read().splitlines()
        except OSError as e:
            return False, f"could not read recipients: {e}"
    # Already present? Idempotent no-op (return ok=True).
    for line in existing_lines:
        if line.strip() == recipient:
            return True, None
    existing_lines.append(recipient)
    return _write_age_recipients_atomic(path, existing_lines)


def _remove_age_recipient(path, recipient):
    """Remove every line whose stripped form equals `recipient`. Preserves
    comments + blank lines. Returns (ok, error_or_None). Removing a
    non-existent recipient is a no-op (returns ok=True) so the UI doesn't
    have to track ghost state."""
    if not os.path.isfile(path):
        return True, None
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError as e:
        return False, f"could not read recipients: {e}"
    new_lines = [line for line in lines if line.strip() != recipient]
    if new_lines == lines:
        return True, None  # nothing to do
    return _write_age_recipients_atomic(path, new_lines)


def make_handler(args):
    def parse_query(path):
        return urllib.parse.parse_qs(urllib.parse.urlparse(path).query)

    def valid_token(path):
        return parse_query(path).get("token", [None])[0] == args.token

    def compose_html():
        with open(args.html) as f:
            shell = f.read()
        with open(args.form_fragment) as f:
            form = f.read()
        with open(args.backups_fragment) as f:
            backups = f.read()
        with open(args.backup_fragment) as f:
            backup = f.read()
        with open(args.restore_fragment) as f:
            restore = f.read()
        with open(args.schedule_fragment) as f:
            schedule = f.read()
        with open(args.runs_fragment) as f:
            runs = f.read()
        with open(args.dashboard_fragment) as f:
            dashboard = f.read()
        with open(args.vault_fragment) as f:
            vault = f.read()
        with open(args.storage_fragment) as f:
            storage = f.read()
        with open(args.scrub_fragment) as f:
            scrub = f.read()
        with open(args.analyze_fragment) as f:
            analyze = f.read()
        # Relative so the browser POSTs to whatever origin served the page —
        # works for loopback, an SSH tunnel, and a non-loopback `dbx serve` bind.
        save_url = f"/save?token={args.token}"
        return (
            shell.replace("<!-- __DBX_FORM_FRAGMENT__ -->", form)
                 .replace("<!-- __DBX_BACKUPS_FRAGMENT__ -->", backups)
                 .replace("<!-- __DBX_BACKUP_FRAGMENT__ -->", backup)
                 .replace("<!-- __DBX_RESTORE_FRAGMENT__ -->", restore)
                 .replace("<!-- __DBX_SCHEDULE_FRAGMENT__ -->", schedule)
                 .replace("<!-- __DBX_RUNS_FRAGMENT__ -->", runs)
                 .replace("<!-- __DBX_DASHBOARD_FRAGMENT__ -->", dashboard)
                 .replace("<!-- __DBX_VAULT_FRAGMENT__ -->", vault)
                 .replace("<!-- __DBX_STORAGE_FRAGMENT__ -->", storage)
                 .replace("<!-- __DBX_SCRUB_FRAGMENT__ -->", scrub)
                 .replace("<!-- __DBX_ANALYZE_FRAGMENT__ -->", analyze)
                 .replace("__DBX_SAVE_URL__", save_url)
        )

    def validate_restore_body(body: dict, container_names: list[str]):
        """Return (argv_tail, error_or_None). argv_tail is the list of args
        after `dbx restore`. Source is the first positional arg."""
        source = body.get("source")
        if not isinstance(source, str) or not source:
            return None, "source is required"

        if SOURCE_HOSTDB_RE.match(source):
            pass  # host/db/latest or host/db/<filename> shape — accept
        else:
            # Must be a path inside data_dir resolving to an existing backup.
            try:
                resolved = os.path.realpath(source)
            except (OSError, ValueError):
                return None, "source path could not be resolved"
            data_root = os.path.realpath(args.data_dir)
            if not (resolved == data_root or resolved.startswith(data_root + os.sep)):
                return None, "source must be inside data-dir or use host/db/latest shape"
            if not os.path.isfile(resolved):
                return None, "source file does not exist"
            if not (resolved.endswith(".sql.zst") or resolved.endswith(".sql.zst.age")
                    or resolved.endswith(".sql.zst.gpg")):
                return None, "source must be a .sql.zst[.age|.gpg] backup file"
            source = resolved  # pass the resolved path to dbx

        argv = [source]

        name = body.get("name")
        if name is not None:
            if not isinstance(name, str) or not NAME_RE.match(name):
                return None, "name must match [A-Za-z0-9][A-Za-z0-9_-]{0,63}"
            argv += ["--name", name]

        into = body.get("into")
        if into is not None:
            if not isinstance(into, str) or into not in container_names:
                return None, "into must reference a currently running container"
            argv += ["--into", into]

        for flag, key in [
            ("--no-post-restore", "no_post_restore"),
            ("--no-scrub",        "no_scrub"),
            ("--hooks-only",      "hooks_only"),
            ("--keep-download",   "keep_download"),
        ]:
            v = body.get(key)
            if v is True:
                argv.append(flag)
            elif v is not None and v is not False:
                return None, f"{key} must be a boolean"

        return argv, None

    def list_configured_hosts() -> list[str]:
        """Return the list of host aliases from config.json. Used to validate
        /api/backup's `host` field — the wizard MUST refuse to invoke
        `dbx backup <host>` for a host the user hasn't configured. Returns
        an empty list if config.json is missing or malformed (caller will
        then 400 with a useful error).

        config.json's `hosts` is an OBJECT keyed by alias (e.g.
        `{"prod-mysql": {"type": "mysql", ...}}`); also tolerate the
        array-of-objects shape for hand-edited / older configs."""
        try:
            with open(args.config_path) as f:
                cfg = json.load(f)
        except (OSError, json.JSONDecodeError):
            return []
        if not isinstance(cfg, dict):
            return []
        hosts = cfg.get("hosts")
        out = []
        if isinstance(hosts, dict):
            for alias, h in hosts.items():
                if isinstance(alias, str) and isinstance(h, dict):
                    out.append(alias)
        elif isinstance(hosts, list):
            for h in hosts:
                if isinstance(h, dict) and isinstance(h.get("alias"), str):
                    out.append(h["alias"])
        return out

    def validate_backup_body(body: dict, configured_hosts: list[str]):
        """Return (argv_tail, error_or_None). argv_tail is the list of args
        after `dbx backup`. Mirrors validate_restore_body's shape."""
        host = body.get("host")
        if not isinstance(host, str) or not host:
            return None, "host is required"
        if not IDENT_RE.match(host):
            return None, "host has invalid characters"
        if host not in configured_hosts:
            return None, f"host '{host}' is not configured (add it in the Config view)"
        argv = []
        # -v goes BEFORE the host argument because cmd_backup parses its
        # flags positionally (lib/core.sh dispatcher). Same constraint
        # mysqldump has with --defaults-extra-file: order matters.
        verbose = body.get("verbose")
        if verbose is True:
            argv.append("-v")
        elif verbose is not None and verbose is not False:
            return None, "verbose must be a boolean"
        upload = body.get("upload")
        if upload is True:
            argv.append("--upload")
        elif upload is not None and upload is not False:
            return None, "upload must be a boolean"
        argv.append(host)
        database = body.get("database")
        if database is not None and database != "":
            if not isinstance(database, str) or not IDENT_RE.match(database):
                return None, "database has invalid characters"
            argv.append(database)
        return argv, None

    def spawn_dbx(subcommand: str, argv_tail: list[str]) -> str:
        """Spawn `dbx <subcommand> <argv_tail>` as a tracked job."""
        argv = [args.dbx_bin, subcommand, *argv_tail]
        # text=True + bufsize=1 = line-buffered string stream from the child.
        popen = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            bufsize=1, text=True,
        )
        job_id = secrets.token_hex(16)
        with JOBS_LOCK:
            JOBS[job_id] = Job(popen)
        return job_id

    def stream_job_events(handler: "H", job: Job):
        handler.send_response(200)
        handler.send_header("Content-Type", "text/event-stream")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("X-Accel-Buffering", "no")  # avoid proxy buffering if any
        handler.end_headers()

        sent = 0
        try:
            while True:
                with job.cv:
                    pending = job.lines[sent:]
                    done = job.finished
                    exit_code = job.exit_code

                for line in pending:
                    msg = f"data: {json.dumps({'line': line})}\n\n"
                    handler.wfile.write(msg.encode())
                    handler.wfile.flush()
                    sent += 1

                if done:
                    msg = f"event: done\ndata: {json.dumps({'exit_code': exit_code})}\n\n"
                    handler.wfile.write(msg.encode())
                    handler.wfile.flush()
                    return

                # Block for new data with a keepalive timeout.
                with job.cv:
                    if sent == len(job.lines) and not job.finished:
                        job.cv.wait(timeout=15.0)
                # Heartbeat comment line keeps proxies/browsers from giving up.
                if sent == len(job.lines) and not job.finished:
                    try:
                        handler.wfile.write(b": keepalive\n\n")
                        handler.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        return
        except (BrokenPipeError, ConnectionResetError):
            # Client gave up. The job keeps running — reconnect is allowed
            # because lines are buffered in memory until server shutdown.
            return

    def send_json(handler, code, payload):
        handler._send(code, json.dumps(payload), "application/json")

    class H(http.server.BaseHTTPRequestHandler):
        def _send(self, code: int, body="", ctype: str = "text/plain"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if body:
                self.wfile.write(body if isinstance(body, bytes) else body.encode())

        def do_GET(self):
            path = urllib.parse.urlparse(self.path).path
            if not valid_token(self.path):
                self._send(403, "missing or bad token")
                return
            if path == "/":
                try:
                    html = compose_html()
                except Exception as e:
                    self._send(500, f"compose failed: {e}")
                    return
                self._send(200, html, "text/html; charset=utf-8")
                return
            if path == "/api/backups":
                send_json(self, 200, list_backups(args.data_dir, args.config_path))
                return
            if path == "/api/backups/download":
                qs = parse_query(self.path)
                raw = (qs.get("path", [""]) or [""])[0]
                resolved, err = _resolve_backup_path(args.data_dir, raw)
                if resolved is None:
                    self._send(400, err or "invalid backup path")
                    return
                try:
                    size = os.path.getsize(resolved)
                    fname = os.path.basename(resolved).replace('"', "").replace("\n", "")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(size))
                    self.send_header("Content-Disposition", f'attachment; filename="{fname}"')
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    with open(resolved, "rb") as fh:
                        shutil.copyfileobj(fh, self.wfile)
                except (OSError, BrokenPipeError, ConnectionResetError):
                    pass
                return
            if path == "/api/audit-log":
                qs = parse_query(self.path)
                # Optional `action` filter. Empty / missing means "all actions".
                action = (qs.get("action", [""]) or [""])[0]
                if action and action not in AUDIT_ACTION_ALLOWLIST:
                    send_json(self, 400, {"error": f"action must be one of: {sorted(AUDIT_ACTION_ALLOWLIST)} or empty"})
                    return
                # `limit` defaults to 50, capped at 500. Reject out-of-range or
                # non-integer values so the caller can't ask the server to
                # tail-bound an audit log that's gigabytes long.
                limit_raw = (qs.get("limit", ["50"]) or ["50"])[0]
                try:
                    limit = int(limit_raw)
                except ValueError:
                    send_json(self, 400, {"error": "limit must be an integer"})
                    return
                if limit < 1 or limit > 500:
                    send_json(self, 400, {"error": "limit must be between 1 and 500"})
                    return
                # Optional outcome filter (allowlisted: 'success' | 'failure').
                outcome = (qs.get("outcome", [""]) or [""])[0]
                if outcome and outcome not in AUDIT_OUTCOME_ALLOWLIST:
                    send_json(self, 400, {"error": f"outcome must be one of: {sorted(AUDIT_OUTCOME_ALLOWLIST)} or empty"})
                    return
                # Optional date range. Bare YYYY-MM-DD becomes anchored to
                # start/end of day; malformed input is silently treated as
                # "no filter" via _parse_audit_date_bound returning None.
                from_raw = (qs.get("from", [""]) or [""])[0]
                to_raw = (qs.get("to", [""]) or [""])[0]
                from_ts = _parse_audit_date_bound(from_raw, end_of_day=False)
                to_ts = _parse_audit_date_bound(to_raw, end_of_day=True)
                # Optional regex over stringified entries. The UI sends the
                # user's raw input; the server compiles it under Python re.
                # On compile error: 400. On invalid-but-syntactically-OK
                # patterns: the regex just won't match anything (caller's
                # problem). Capped at AUDIT_REGEX_MAX_LEN to bound ReDoS.
                q_raw = (qs.get("q", [""]) or [""])[0]
                pattern = None
                if q_raw:
                    if len(q_raw) > AUDIT_REGEX_MAX_LEN:
                        send_json(self, 400, {"error": f"q pattern too long (max {AUDIT_REGEX_MAX_LEN} chars)"})
                        return
                    try:
                        pattern = re.compile(q_raw)
                    except re.error as e:
                        send_json(self, 400, {"error": f"invalid regex: {e}"})
                        return
                # Backwards-compat shape: only the legacy params (`action`,
                # `limit`) means "return bare array" — that's what the old
                # tests + any external consumers depend on. The moment any of
                # the new filter params (or the explicit `format=v2` opt-in)
                # show up, we return the envelope `{entries,total,filtered}`
                # so the UI can render "Showing M of N".
                use_envelope = (
                    bool(from_raw) or bool(to_raw) or bool(q_raw)
                    or bool(outcome) or qs.get("format", [""])[0] == "v2"
                )
                result = list_audit_log(
                    args.audit_dir, action, limit,
                    from_ts=from_ts, to_ts=to_ts,
                    pattern=pattern, outcome=outcome or None,
                )
                if use_envelope:
                    send_json(self, 200, result)
                else:
                    send_json(self, 200, result["entries"])
                return
            if path == "/api/containers":
                send_json(self, 200, list_containers())
                return
            if path == "/api/restore/diff":
                # Guided-restore step-3 preview. Resolves the source backup,
                # reads its meta.json for flavor, then asks docker whether
                # the target db exists in the managed container. Silent
                # docker failures degrade to "target will be CREATED" — no
                # docker is required for the endpoint to return useful info.
                qs = parse_query(self.path)
                source = (qs.get("source", [""]) or [""])[0]
                target = (qs.get("target", [""]) or [""])[0]
                payload, err = compute_restore_diff(
                    source, target, args.data_dir, args.config_path,
                )
                if err is not None:
                    send_json(self, 400, {"error": err})
                    return
                send_json(self, 200, payload)
                return
            if path == "/api/schedules":
                try:
                    state = read_schedule_state(args.lib_dir, args.config_path, args.data_dir, args.audit_dir)
                except RuntimeError as e:
                    send_json(self, 500, {"error": str(e)})
                    return
                send_json(self, 200, state)
                return
            if path == "/api/storage/usage":
                send_json(self, 200, compute_storage_usage(args.data_dir))
                return
            if path == "/api/storage/clean-preview":
                qs = parse_query(self.path)
                keep_raw = (qs.get("keep", [""]) or [""])[0]
                older_raw = (qs.get("older_than", [""]) or [""])[0]
                if not keep_raw and not older_raw:
                    send_json(self, 400, {"error": "at least one of keep or older_than is required"})
                    return
                keep_n = None
                older_n = None
                if keep_raw:
                    try:
                        keep_n = int(keep_raw)
                    except ValueError:
                        send_json(self, 400, {"error": "keep must be an integer"})
                        return
                    if keep_n < 1 or keep_n > 1000:
                        send_json(self, 400, {"error": "keep must be between 1 and 1000"})
                        return
                if older_raw:
                    try:
                        older_n = int(older_raw)
                    except ValueError:
                        send_json(self, 400, {"error": "older_than must be an integer"})
                        return
                    if older_n < 1 or older_n > 3650:
                        send_json(self, 400, {"error": "older_than must be between 1 and 3650"})
                        return
                would_delete, reclaim_bytes, reclaim_count = compute_clean_preview(
                    args.data_dir, keep_n, older_n
                )
                send_json(self, 200, {
                    "would_delete": would_delete,
                    "reclaim_bytes": reclaim_bytes,
                    "reclaim_count": reclaim_count,
                })
                return
            if path == "/api/dashboard":
                # Composed view: host/db pairs from DATA_DIR + per-pair
                # last_success/last_failure from audit.log + schedules[]
                # from config.json. Always returns 200; missing audit log
                # / config / data dir all degrade to empty payloads rather
                # than 5xx.
                send_json(self, 200, compute_dashboard(
                    args.data_dir, args.audit_dir, args.config_path
                ))
                return
            if path == "/api/config":
                # Used by the Config view to pre-populate the form with the
                # user's existing config.json instead of starting blank.
                if not os.path.isfile(args.config_path):
                    send_json(self, 200, {})
                    return
                try:
                    with open(args.config_path) as f:
                        cfg = json.load(f)
                except (OSError, json.JSONDecodeError) as e:
                    send_json(self, 500, {"error": f"could not read config: {e}"})
                    return
                send_json(self, 200, cfg if isinstance(cfg, dict) else {})
                return
            if path == "/api/vault/list":
                # Shell out to `dbx vault list` for the keys + `dbx vault info`
                # for the backend label. Audit log gives `last_set` per key
                # via a single full-log scan (cheap; audit logs are tiny).
                keys = _list_vault_keys(args.dbx_bin)
                backend = _detect_vault_backend(args.dbx_bin)
                last_set_map = _vault_last_set_map(args.audit_dir)
                rows = [
                    {
                        "key": k,
                        "backend": backend,
                        "last_set": last_set_map.get(k),
                    }
                    for k in keys
                ]
                send_json(self, 200, rows)
                return
            if path == "/api/vault/get":
                qs = parse_query(self.path)
                key = (qs.get("key", [""]) or [""])[0]
                if not VAULT_KEY_RE.match(key):
                    send_json(self, 400, {"error": "key must match [A-Za-z0-9._-]{1,64}"})
                    return
                # capture_output=True keeps stdout in memory so the value
                # never lands on the wizard's stderr/log. The CLI's own
                # `audit_vault "get"` is not emitted by cmd_vault get
                # today, but if added later we won't be double-counting.
                try:
                    result = subprocess.run(
                        [args.dbx_bin, "vault", "get", key],
                        capture_output=True, text=True, timeout=10, check=False,
                    )
                except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as e:
                    send_json(self, 500, {"error": f"dbx vault get failed to spawn: {e}"})
                    return
                if result.returncode != 0:
                    # Surface a generic error — stderr may carry the CLI's
                    # 'No credentials found for: <key>' message; pass it
                    # through trimmed so the UI can show it.
                    err = (result.stderr or "").strip().splitlines()
                    msg = err[-1] if err else f"exit {result.returncode}"
                    send_json(self, 404, {"error": msg})
                    return
                # dbx vault get prints `echo "$pass"` — strip the trailing
                # newline that echo adds. Do NOT strip whitespace because a
                # legitimate password could be space-padded.
                value = result.stdout
                if value.endswith("\n"):
                    value = value[:-1]
                send_json(self, 200, {"key": key, "value": value})
                return
            if path == "/api/vault/age-recipients":
                path_to_file = _age_recipients_path()
                recipients, err = _read_age_recipients(path_to_file)
                if err is not None:
                    send_json(self, 500, {"error": err})
                    return
                send_json(self, 200, {"path": path_to_file, "recipients": recipients})
                return
            if path == "/api/scrub/status":
                send_json(self, 200, scrub_status(args.config_path))
                return
            if path == "/api/scrub/manifest":
                qs = parse_query(self.path)
                host = (qs.get("host", [""]) or [""])[0]
                if not host or not IDENT_RE.match(host):
                    send_json(self, 400, {"error": "host is required and must match the alias shape"})
                    return
                manifest, resolved, err = read_scrub_manifest(args.config_path, host)
                if err is not None:
                    send_json(self, 400, {"error": err})
                    return
                send_json(self, 200, {
                    "host": host,
                    "manifest_path": resolved,
                    "manifest": manifest,
                })
                return
            m = re.match(r"^/api/jobs/([0-9a-f]{32})/events$", path)
            if m:
                with JOBS_LOCK:
                    job = JOBS.get(m.group(1))
                if job is None:
                    self._send(404, "no such job")
                    return
                stream_job_events(self, job)
                return
            self._send(404, "not found")

        def do_POST(self):
            path = urllib.parse.urlparse(self.path).path
            if not valid_token(self.path):
                self._send(403, "forbidden")
                return

            if path in ("/save", "/api/config-save"):
                # /save           = write config + signal done-marker (bash exits)
                # /api/config-save = write config, keep the wizard running
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 1_000_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    form_cfg = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(form_cfg, dict):
                    self._send(400, "body must be a JSON object")
                    return
                # Merge form payload into existing config.json so non-form
                # top-level keys (schedules, scrub, vault, ...) survive. Form-
                # managed keys are replaced with what the form sent — including
                # being DELETED if the form omitted them (e.g., user unchecked
                # storage.enabled). Keys outside the form-managed list are
                # preserved verbatim.
                FORM_MANAGED = {"hosts", "defaults", "storage", "notifications"}
                try:
                    if os.path.isfile(args.config_path):
                        with open(args.config_path) as f:
                            existing = json.load(f)
                        if not isinstance(existing, dict):
                            existing = {}
                    else:
                        existing = {}
                except (OSError, json.JSONDecodeError):
                    existing = {}
                merged = {k: v for k, v in existing.items() if k not in FORM_MANAGED}
                for k in FORM_MANAGED:
                    if k in form_cfg:
                        merged[k] = form_cfg[k]
                try:
                    os.makedirs(os.path.dirname(args.config_path), exist_ok=True)
                    tmp_path = args.config_path + ".wizard-tmp"
                    with open(tmp_path, "w") as f:
                        json.dump(merged, f, indent=2)
                        f.write("\n")
                    os.chmod(tmp_path, 0o600)
                    os.replace(tmp_path, args.config_path)
                except OSError as e:
                    self._send(500, f"write failed: {e}")
                    return
                if path == "/save" and args.done_marker:
                    with open(args.done_marker, "w") as f:
                        f.write("ok\n")
                self._send(200, '{"ok":true}', "application/json")
                return

            if path == "/api/restore":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 64_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    self._send(400, "body must be a JSON object")
                    return
                argv_tail, err = validate_restore_body(body, list_containers())
                if err is not None:
                    send_json(self, 400, {"error": err})
                    return
                assert argv_tail is not None
                try:
                    job_id = spawn_dbx("restore", argv_tail)
                except OSError as e:
                    self._send(500, f"spawn failed: {e}")
                    return
                send_json(self, 200, {"job_id": job_id})
                return

            if path == "/api/backup":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 8_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    self._send(400, "body must be a JSON object")
                    return
                configured = list_configured_hosts()
                if not configured:
                    send_json(self, 400, {"error": "no hosts configured in config.json"})
                    return
                argv_tail, err = validate_backup_body(body, configured)
                if err is not None:
                    send_json(self, 400, {"error": err})
                    return
                assert argv_tail is not None
                try:
                    job_id = spawn_dbx("backup", argv_tail)
                except OSError as e:
                    self._send(500, f"spawn failed: {e}")
                    return
                send_json(self, 200, {"job_id": job_id})
                return

            if path == "/api/host-test":
                # PR-Y4: per-host connection test from the dashboard. Wraps
                # `dbx test <host>` as a streaming job so the UI can show the
                # 4-step staged check (ssh / container / creds / query) live.
                # Host must match IDENT_RE AND appear in the configured-hosts
                # allowlist — same shape as /api/backup, since we're spawning
                # the same kind of dbx subprocess against an alias the user
                # claimed they own.
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 8_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    self._send(400, "body must be a JSON object")
                    return
                host = body.get("host")
                if not isinstance(host, str) or not host:
                    send_json(self, 400, {"error": "host is required"})
                    return
                if not IDENT_RE.match(host):
                    send_json(self, 400, {"error": "host has invalid characters"})
                    return
                configured = list_configured_hosts()
                if host not in configured:
                    send_json(self, 400, {"error": f"host '{host}' is not configured"})
                    return
                try:
                    job_id = spawn_dbx("test", [host])
                except OSError as e:
                    self._send(500, f"spawn failed: {e}")
                    return
                send_json(self, 200, {"job_id": job_id})
                return

            if path == "/api/storage/clean":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 8_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                keep_v = body.get("keep")
                older_v = body.get("older_than")
                # Same shape validation the GET preview uses — keep them in
                # lockstep so a preview that succeeds also spawns cleanly.
                if keep_v is None and older_v is None:
                    send_json(self, 400, {"error": "at least one of keep or older_than is required"})
                    return
                argv = []
                if keep_v is not None:
                    if not isinstance(keep_v, int) or isinstance(keep_v, bool):
                        send_json(self, 400, {"error": "keep must be an integer"})
                        return
                    if keep_v < 1 or keep_v > 1000:
                        send_json(self, 400, {"error": "keep must be between 1 and 1000"})
                        return
                    argv += ["--keep", str(keep_v)]
                if older_v is not None:
                    if not isinstance(older_v, int) or isinstance(older_v, bool):
                        send_json(self, 400, {"error": "older_than must be an integer"})
                        return
                    if older_v < 1 or older_v > 3650:
                        send_json(self, 400, {"error": "older_than must be between 1 and 3650"})
                        return
                    argv += ["--older-than", str(older_v)]
                dry = body.get("dry_run")
                if dry is True:
                    argv.append("--dry-run")
                elif dry is not None and dry is not False:
                    send_json(self, 400, {"error": "dry_run must be a boolean"})
                    return
                try:
                    job_id = spawn_dbx("clean", argv)
                except OSError as e:
                    self._send(500, f"spawn failed: {e}")
                    return
                send_json(self, 200, {"job_id": job_id})
                return

            if path == "/api/schedules":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 256_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict) or "schedules" not in body:
                    send_json(self, 400, {"error": "body must be {schedules: [...]}"})
                    return
                ok, err = write_schedules_block(args.config_path, body["schedules"])
                if not ok:
                    send_json(self, 400, {"error": err})
                    return
                send_json(self, 200, {"ok": True})
                return

            if path == "/api/backups/delete":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 8_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                ok, err = delete_backup(args.data_dir, body.get("path"))
                if not ok:
                    send_json(self, 400, {"error": err})
                    return
                send_json(self, 200, {"ok": True})
                return

            if path == "/api/vault/set":
                length = int(self.headers.get("Content-Length", 0))
                # Body cap: 8KB is plenty for key + 4KB value + JSON braces.
                if length <= 0 or length > 8_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                key = body.get("key")
                value = body.get("value")
                if not isinstance(key, str) or not VAULT_KEY_RE.match(key):
                    send_json(self, 400, {"error": "key must match [A-Za-z0-9._-]{1,64}"})
                    return
                if not isinstance(value, str):
                    send_json(self, 400, {"error": "value must be a string"})
                    return
                # Length cap in BYTES (UTF-8) — the spec quotes 4096 bytes,
                # which differs from Python len() for any non-ASCII content.
                if len(value.encode("utf-8")) > VAULT_VALUE_MAX_BYTES:
                    send_json(self, 400, {"error": f"value exceeds {VAULT_VALUE_MAX_BYTES} bytes"})
                    return
                if not value:
                    send_json(self, 400, {"error": "value must not be empty"})
                    return
                # `dbx vault set <key>` does `read -rs password` from stdin.
                # We pipe via stdin=PIPE so the value never enters argv (it
                # would be visible to `ps`). capture_output=True keeps both
                # streams in memory so nothing leaks to the wizard's log.
                try:
                    proc = subprocess.run(
                        [args.dbx_bin, "vault", "set", key],
                        input=value + "\n", capture_output=True, text=True,
                        timeout=15, check=False,
                    )
                except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as e:
                    send_json(self, 500, {"error": f"dbx vault set failed to spawn: {e}"})
                    return
                if proc.returncode != 0:
                    err = (proc.stderr or "").strip().splitlines()
                    msg = err[-1] if err else f"exit {proc.returncode}"
                    send_json(self, 400, {"error": msg})
                    return
                send_json(self, 200, {"ok": True})
                return

            if path == "/api/vault/delete":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 2_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                key = body.get("key")
                if not isinstance(key, str) or not VAULT_KEY_RE.match(key):
                    send_json(self, 400, {"error": "key must match [A-Za-z0-9._-]{1,64}"})
                    return
                try:
                    proc = subprocess.run(
                        [args.dbx_bin, "vault", "delete", key],
                        capture_output=True, text=True, timeout=10, check=False,
                    )
                except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as e:
                    send_json(self, 500, {"error": f"dbx vault delete failed to spawn: {e}"})
                    return
                # cmd_vault delete returns 0 even when the key doesn't
                # exist (it just logs "No credentials found"). We forward
                # 200 regardless so the UI's "remove and refresh" flow
                # stays idempotent.
                if proc.returncode != 0:
                    err = (proc.stderr or "").strip().splitlines()
                    msg = err[-1] if err else f"exit {proc.returncode}"
                    send_json(self, 400, {"error": msg})
                    return
                send_json(self, 200, {"ok": True})
                return

            if path == "/api/vault/age-recipients/add":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 2_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                recipient = body.get("recipient")
                if not isinstance(recipient, str) or not AGE_RECIPIENT_RE.match(recipient):
                    send_json(self, 400, {"error": "recipient must match age1[a-z0-9]{50,80}"})
                    return
                ok, err = _add_age_recipient(_age_recipients_path(), recipient)
                if not ok:
                    send_json(self, 500, {"error": err})
                    return
                send_json(self, 200, {"ok": True})
                return

            if path == "/api/vault/age-recipients/remove":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 2_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                recipient = body.get("recipient")
                # Permissive for remove — accept any string so the user can
                # clean up a malformed line that snuck in via a manual edit.
                # Cap length so a non-string or huge value can't trash the file.
                if not isinstance(recipient, str) or not recipient or len(recipient) > 256:
                    send_json(self, 400, {"error": "recipient must be a non-empty string ≤256 chars"})
                    return
                ok, err = _remove_age_recipient(_age_recipients_path(), recipient)
                if not ok:
                    send_json(self, 500, {"error": err})
                    return
                send_json(self, 200, {"ok": True})
                return

            if path in ("/api/scrub/init", "/api/scrub/check"):
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 8_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                host = body.get("host")
                database = body.get("database")
                if not isinstance(host, str) or not IDENT_RE.match(host):
                    if host not in ("local", "localhost"):
                        send_json(self, 400, {"error": "host must match the alias shape or be 'local'"})
                        return
                if not isinstance(database, str) or not IDENT_RE.match(database):
                    send_json(self, 400, {"error": "database must match the db-name shape"})
                    return
                target = f"{host}/{database}"

                if path == "/api/scrub/init":
                    argv = ["init", target]
                    if body.get("include_empty") is True:
                        argv.append("--include-empty")
                    elif body.get("include_empty") not in (None, False):
                        send_json(self, 400, {"error": "include_empty must be a boolean"})
                        return
                    code, stdout, stderr = run_scrub_subcommand(args.dbx_bin, argv)
                    if code != 0:
                        send_json(self, 502, {
                            "error": "scrub init failed",
                            "exit_code": code,
                            "stderr": stderr,
                            "stdout": stdout,
                        })
                        return
                    try:
                        manifest = json.loads(stdout)
                    except json.JSONDecodeError as e:
                        send_json(self, 502, {
                            "error": f"scrub init returned non-JSON: {e}",
                            "stdout": stdout,
                            "stderr": stderr,
                        })
                        return
                    send_json(self, 200, {"ok": True, "manifest": manifest, "stderr": stderr})
                    return

                argv = ["check", target, "--json"]
                manifest_override = body.get("manifest_path")
                if manifest_override is not None:
                    if not isinstance(manifest_override, str) or not manifest_override:
                        send_json(self, 400, {"error": "manifest_path must be a non-empty string"})
                        return
                    argv += ["--manifest", manifest_override]
                code, stdout, stderr = run_scrub_subcommand(args.dbx_bin, argv)
                if code in (0, 2):
                    try:
                        report = json.loads(stdout)
                    except json.JSONDecodeError as e:
                        send_json(self, 502, {
                            "error": f"scrub check returned non-JSON: {e}",
                            "stdout": stdout,
                            "stderr": stderr,
                        })
                        return
                    send_json(self, 200, {
                        "ok": code == 0,
                        "report": report,
                        "stderr": stderr,
                    })
                    return
                send_json(self, 502, {
                    "error": "scrub check failed",
                    "exit_code": code,
                    "stderr": stderr,
                    "stdout": stdout,
                })
                return

            if path == "/api/scrub/save":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 1_000_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                ok, err = write_scrub_manifest(
                    body.get("manifest_path"),
                    args.config_path,
                    body.get("manifest"),
                    body.get("host"),
                )
                if not ok:
                    send_json(self, 400, {"error": err})
                    return
                send_json(self, 200, {"ok": True})
                return

            if path == "/api/analyze":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 8_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                host = body.get("host")
                database = body.get("database")
                if not isinstance(host, str) or not IDENT_RE.match(host):
                    send_json(self, 400, {"error": "host must match the alias shape"})
                    return
                if not isinstance(database, str) or not IDENT_RE.match(database):
                    send_json(self, 400, {"error": "database must match the db-name shape"})
                    return
                no_pii = body.get("no_pii_scan")
                if no_pii is not None and not isinstance(no_pii, bool):
                    send_json(self, 400, {"error": "no_pii_scan must be a boolean"})
                    return
                code, stdout, stderr = run_analyze_json(
                    args.dbx_bin, host, database, no_pii_scan=bool(no_pii)
                )
                if code != 0:
                    send_json(self, 502, {
                        "error": "dbx analyze failed",
                        "exit_code": code,
                        "stderr": stderr,
                        "stdout": stdout,
                    })
                    return
                try:
                    payload = json.loads(stdout)
                except json.JSONDecodeError as e:
                    send_json(self, 502, {
                        "error": f"dbx analyze returned non-JSON: {e}",
                        "stdout": stdout,
                        "stderr": stderr,
                    })
                    return
                # Pass stderr through on success too — `dbx analyze` emits
                # log_step "Scanning for PII..." / log_warn messages on
                # stderr that the wizard's diagnostics panel surfaces.
                # Empty string elided so the UI doesn't render an empty box.
                if stderr:
                    payload["stderr"] = stderr
                send_json(self, 200, payload)
                return

            if path == "/api/analyze/exclude":
                length = int(self.headers.get("Content-Length", 0))
                if length <= 0 or length > 1_000_000:
                    self._send(400, "bad length")
                    return
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    self._send(400, f"invalid json: {e}")
                    return
                if not isinstance(body, dict):
                    send_json(self, 400, {"error": "body must be a JSON object"})
                    return
                ok, err = write_exclude_data(
                    args.config_path,
                    body.get("host"),
                    body.get("database"),
                    body.get("exclude_data"),
                )
                if not ok:
                    send_json(self, 400, {"error": err})
                    return
                send_json(self, 200, {"ok": True})
                return

            m = re.match(r"^/api/jobs/([0-9a-f]{32})/cancel$", path)
            if m:
                with JOBS_LOCK:
                    job = JOBS.get(m.group(1))
                if job is None:
                    self._send(404, "no such job")
                    return
                cancelled = job.cancel()
                send_json(self, 200, {"ok": True, "cancelled": cancelled})
                return

            self._send(404, "not found")

        def log_message(self, format, *args):  # noqa: A002 - match base class signature
            _ = (format, args)  # silence per-request stderr logging

    return H


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """One thread per request — SSE streams hold a thread for the duration of
    the restore, so the default single-threaded HTTPServer would deadlock the
    second concurrent request."""
    daemon_threads = True
    allow_reuse_address = True


def main():
    args = parse_args()
    httpd = ThreadingHTTPServer((args.host, args.port), make_handler(args))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        # Terminate any in-flight restore jobs so we don't leave orphans.
        with JOBS_LOCK:
            for job in JOBS.values():
                try:
                    job.cancel()
                except Exception:
                    pass


if __name__ == "__main__":
    main()
