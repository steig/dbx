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
        "--audit-dir",
        default=os.environ.get(
            "DBX_AUDIT_DIR",
            os.path.join(os.environ.get("HOME", ""), ".local", "share", "dbx"),
        ),
        help="Directory containing audit.log (default: $DBX_AUDIT_DIR or ~/.local/share/dbx)",
    )
    p.add_argument("--done-marker", required=True, help="Touched after a successful save")
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


def delete_backup(data_dir: str, raw_path):
    """Remove a backup file and its .meta.json sidecar. `raw_path` is
    intentionally untyped — it comes from arbitrary JSON. Strict validation:
    path must resolve (via realpath) to a regular file inside DATA_DIR with
    a `*.sql.zst[.age|.gpg]` suffix. Returns (ok, error_or_None).

    Symlinks: realpath resolves them and we still require the resolved path
    to be inside DATA_DIR — so a symlink under DATA_DIR pointing outside
    is correctly rejected. The sidecar deletion is best-effort (a backup
    without a sidecar is "incomplete" and we still want to clear it)."""
    if not isinstance(raw_path, str) or not raw_path:
        return False, "path is required"
    try:
        resolved = os.path.realpath(raw_path)
    except (OSError, ValueError):
        return False, "path could not be resolved"
    data_root = os.path.realpath(data_dir)
    if not (resolved == data_root or resolved.startswith(data_root + os.sep)):
        return False, "path must be inside data-dir"
    if not (resolved.endswith(".sql.zst") or resolved.endswith(".sql.zst.age")
            or resolved.endswith(".sql.zst.gpg")):
        return False, "path must be a .sql.zst[.age|.gpg] backup file"
    if not os.path.isfile(resolved):
        return False, "backup file does not exist"
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


def list_audit_log(audit_dir: str, action: str, limit: int):
    """Return up to `limit` JSON-parsed entries from the tail of
    `<audit_dir>/audit.log`, newest first, optionally filtered by `action`.

    Performance: the audit log is append-only and grows forever (see
    core.sh:651). We avoid reading the whole file by tailing the last
    `limit * 2` lines via `tail -N`, then parsing + filtering + truncating
    in memory. `limit * 2` is a heuristic: after action-filtering you may
    have fewer matches than `limit`, so reading 2x gives a reasonable
    cushion without unbounded I/O.

    Returns [] when the file doesn't exist (not an error: the audit log
    is lazily created on first audited operation).
    """
    audit_path = os.path.join(audit_dir, "audit.log")
    if not os.path.isfile(audit_path):
        return []
    # Tail-bounded read: ask `tail` for the last `limit * 2` lines so we
    # have some slack when filtering by action. Fall back to a Python
    # implementation if tail isn't available (edge case; tail is in
    # coreutils + macOS base system).
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
            return []

    entries = []
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
        if action and entry.get("action") != action:
            continue
        entries.append(entry)

    # Newest first. `tail` already gave us newest at the end; reverse to put
    # newest first, then truncate to `limit`.
    entries.reverse()
    return entries[:limit]


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


def read_schedule_state(lib_dir: str, config_path: str, data_dir: str):
    """Source core.sh + schedule.sh in a bash subprocess and read all three
    TSV blocks (declarative / installed / sync plan). Returns a dict suitable
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

    return {
        "declarative": parse_tsv_rows(sections["__CFG__"], ["host", "database", "when"]),
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
        cleaned.append({"host": host, "database": database, "when": when})

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
    }


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
        save_url = f"http://127.0.0.1:{args.port}/save?token={args.token}"
        return (
            shell.replace("<!-- __DBX_FORM_FRAGMENT__ -->", form)
                 .replace("<!-- __DBX_BACKUPS_FRAGMENT__ -->", backups)
                 .replace("<!-- __DBX_BACKUP_FRAGMENT__ -->", backup)
                 .replace("<!-- __DBX_RESTORE_FRAGMENT__ -->", restore)
                 .replace("<!-- __DBX_SCHEDULE_FRAGMENT__ -->", schedule)
                 .replace("<!-- __DBX_RUNS_FRAGMENT__ -->", runs)
                 .replace("<!-- __DBX_DASHBOARD_FRAGMENT__ -->", dashboard)
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
                send_json(self, 200, list_audit_log(args.audit_dir, action, limit))
                return
            if path == "/api/containers":
                send_json(self, 200, list_containers())
                return
            if path == "/api/schedules":
                try:
                    state = read_schedule_state(args.lib_dir, args.config_path, args.data_dir)
                except RuntimeError as e:
                    send_json(self, 500, {"error": str(e)})
                    return
                send_json(self, 200, state)
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
                if path == "/save":
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
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(args))
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
