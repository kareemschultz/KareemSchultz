@echo off
setlocal
title Bettencourt HR - One File Attendance Setup
set "BETTENCOURT_INSTALLER_SOURCE=%~f0"
fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting Administrator access...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:BETTENCOURT_INSTALLER_SOURCE -Verb RunAs -Wait"
  exit /b %ERRORLEVEL%
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText($env:BETTENCOURT_INSTALLER_SOURCE); $m=[char]35+' BETTENCOURT_INSTALLER_POWERSHELL_START'; $n=$f.LastIndexOf($m); if($n -lt 0){throw 'Incomplete installer'}; & ([scriptblock]::Create($f.Substring($n+$m.Length)))"
set "BETTENCOURT_EXIT=%ERRORLEVEL%"
echo.
echo Press any key to close the installer.
pause >nul
exit /b %BETTENCOURT_EXIT%
# BETTENCOURT_INSTALLER_POWERSHELL_START
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$taskName = 'BettencourtHR-NGTecoSync'
$installDir = 'C:\BettencourtHR\ngteco-agent'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Step([string]$s) {
    Write-Host ''
    Write-Host ('== ' + $s + ' ==') -ForegroundColor Cyan
}
function SecretPrompt([string]$message) {
    $secure = Read-Host -Prompt $message -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Find-Python {
    $locations = @(
        "$env:ProgramFiles\Python312\python.exe",
        "$env:ProgramFiles\Python313\python.exe",
        "$env:ProgramFiles\Python314\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python314\python.exe"
    )
    foreach ($p in $locations) {
        if (-not (Test-Path $p)) { continue }
        try {
            $v = & $p -c "import sys; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor))" 2>$null
            if (($LASTEXITCODE -eq 0) -and ([version]$v -ge [version]'3.10')) {
                return @{Exe=$p; Args=@()}
            }
        } catch {}
    }
    foreach ($p in @('py','python')) {
        if (-not (Get-Command $p -ErrorAction SilentlyContinue)) { continue }
        $selectors = @('')
        if ($p -eq 'py') { $selectors = @('-3.12','-3','') }
        foreach ($selector in $selectors) {
            $args = @()
            if ($selector) { $args = @($selector) }
            try {
                $v = & $p @args -c "import sys; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor))" 2>$null
                if (($LASTEXITCODE -eq 0) -and ([version]$v -ge [version]'3.10')) {
                    return @{Exe=$p; Args=$args}
                }
            } catch {}
        }
    }
    return $null
}
function Existing-Config([string]$path) {
    $cfg = @{}
    if (Test-Path $path) {
        foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
            if ($line -match '^([A-Z_]+)=(.*)$') { $cfg[$matches[1]] = $matches[2] }
        }
    }
    return $cfg
}
try {
    Step 'Bettencourt HR — single-file attendance installer'
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($me)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges required.'
    }
    Write-Host 'Installs the NGTeco K4 sync, including startup and five-minute schedules.'
    Write-Host 'Requires Internet access for initial Python package installation.'
    Step 'Locating or installing Python 3.10+'
    $pythonChoice = Find-Python
    if (-not $pythonChoice) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw 'Python not installed and WinGet unavailable. Install Python 3.12 for all users from python.org and rerun.'
        }
        Write-Host 'Installing official Python 3.12 via Windows Package Manager...'
        & winget.exe install --id Python.Python.3.12 --exact --scope machine --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw ('WinGet Python install failed: ' + $LASTEXITCODE) }
        $pythonChoice = Find-Python
        if (-not $pythonChoice) { throw 'Python not visible after installation. Restart Windows and rerun.' }
    }
    $pyExe = $pythonChoice.Exe
    $pyArgs = $pythonChoice.Args
    Write-Host ('Using Python: ' + $pyExe)
    Step 'Collecting on-site configuration'
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $cfgPath = Join-Path $installDir '.env'
    $cfg = Existing-Config $cfgPath
    $clockIP = '192.168.10.5'
    if ($cfg.ContainsKey('NGTECO_K4_IP') -and $cfg['NGTECO_K4_IP']) { $clockIP = $cfg['NGTECO_K4_IP'] }
    $enteredIP = Read-Host ('Clock IP [' + $clockIP + '] (Enter keeps this value)')
    if (-not [string]::IsNullOrWhiteSpace($enteredIP)) { $clockIP = $enteredIP.Trim() }
    $validIp = $null
    if (-not [Net.IPAddress]::TryParse($clockIP,[ref]$validIp)) { throw 'Invalid clock IP.' }
    $apiKey = ''
    if ($cfg.ContainsKey('DEVICE_API_KEY')) { $apiKey = $cfg['DEVICE_API_KEY'] }
    if (-not $apiKey) { $apiKey = SecretPrompt 'DEVICE_API_KEY from Infisical (input hidden)' }
    if ([string]::IsNullOrWhiteSpace($apiKey) -or $apiKey.Contains([char]10) -or $apiKey.Contains([char]13)) {
        throw 'Valid DEVICE_API_KEY required.'
    }
    $healthUrl = ''
    if ($cfg.ContainsKey('HEALTHCHECK_PING_URL')) { $healthUrl = $cfg['HEALTHCHECK_PING_URL'] }
    if (-not $healthUrl) { $healthUrl = SecretPrompt 'HEALTHCHECK_PING_URL (optional, input hidden)' }
    if ($healthUrl -and -not $healthUrl.StartsWith('https://',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Healthcheck ping URL must use HTTPS.'
    }
    Step 'Writing bundled agent files'
    $files = @{}
    $files['sync_ngteco_punches.py'] = @'
#!/usr/bin/env python3
"""
NGTeco K4 -> Bettencourt HR punch sync
=======================================
Fetches the authenticated Bettencourt HR roster, preloads names onto the
NGTeco K4 clock (proven reachable via the ZK protocol — see
ngteco_k4_probe.py test), then pulls attendance punches and POSTs them over
HTTPS to the Bettencourt HR app's /api/attendance/ingest endpoint.
Idempotent: the server dedupes on (device_serial, device_user_id, timestamp),
so it's safe to run this every few minutes via Task Scheduler/cron without
tracking what was already sent.

This runs on-site, on the same LAN as the clock (10.69.10.60) — the app
server (kt-titan-01) has no route to that private IP, so this script is the
only thing that can ever talk to the device. It only ever reads from the
clock and POSTs outward; the server never reaches back in.

Setup:
    pip install pyzk requests python-dotenv --break-system-packages
    (or inside the venv already used for ngteco_k4_probe.py)

Env vars (put in a .env next to this script, or set in Task Scheduler /
docker-compose.agent.yml):
    INGEST_URL           - e.g. https://hr.bettencourtgy.com/api/attendance/ingest
    ROSTER_URL           - optional. Defaults to INGEST_URL with the final
                           /ingest path segment replaced by /roster. The
                           same bearer key is used. Roster fetch/validation
                           happens before the clock is mutated or punches are
                           read; failure exits non-zero and leaves onboard
                           punch logs untouched, so the next run can retry and
                           the dead-man healthcheck exposes the failure.
    DEVICE_API_KEY       - raw bearer key issued via `pnpm device:issue-key`
    NGTECO_K4_IP         - default 10.69.10.60
    NGTECO_K4_PORT       - default 4370
    HEALTHCHECK_PING_URL - optional. Dead-man's-switch ping (healthchecks.io,
                           self-hosted at healthchecks.karetechsolutions.com,
                           check name `bettencourt-ngteco-clock`) hit after
                           every fully-successful sync. This is the actual
                           offline-alerting mechanism for this deployment: if
                           the clock or this agent goes dark, nothing pings
                           and healthchecks.io's own grace-period alert fires
                           — there is no in-app equivalent, since a
                           single-device fleet can't detect its own silence.
                           Best-effort; a failed ping never fails the script.
    SYNC_STATE_PATH      - optional. Where the watermark (timestamp of the
                           last successfully-ingested punch) is persisted
                           between runs, so each run only sends punches newer
                           than what already made it to the server instead of
                           re-sending the device's entire history every time.
                           Default: sync_state.json next to this script. NOT
                           committed to git (see .gitignore).

Usage:
    python sync_ngteco_punches.py
    python sync_ngteco_punches.py --dry-run   # GET roster/read device, but skip mutations/POST/state/ping
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone, timedelta
from urllib.parse import urlsplit, urlunsplit

# The K4 clock is set to Guyana local time (verified during the probe:
# device time matched wall-clock Georgetown time). Guyana is UTC-4 with
# NO daylight saving, so a fixed offset is correct and immune to Windows
# tz-database quirks. pyzk returns naive datetimes in the device's local
# time; we attach this offset so the server (which stores true UTC) tags
# every punch correctly.
GUYANA_TZ = timezone(timedelta(hours=-4), name="America/Guyana")

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

DEVICE_IP = os.environ.get("NGTECO_K4_IP", "10.69.10.60")
DEVICE_PORT = int(os.environ.get("NGTECO_K4_PORT", "4370"))
DEVICE_SERIAL = "GED7253100495"  # confirmed via probe; guards multi-device future

MAX_RETRIES = 3
RETRY_BACKOFF_SECONDS = 5  # doubles each retry: 5s, 10s, 20s

# Keeps each POST comfortably under the ingest route's own MAX_PUNCHES cap
# (5000 — see app/api/attendance/ingest/route.ts) so a large backlog (e.g.
# the very first sync against a clock that already has months of history)
# goes out over a few consecutive requests in the same run instead of one
# oversized request that the route would reject outright.
BATCH_SIZE = 2000
DEVICE_USER_ID_MIN = 1
DEVICE_USER_ID_MAX = 65_535
DEVICE_NAME_MAX_LENGTH = 24
ORDINARY_PRIVILEGE = 0

DEFAULT_STATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sync_state.json")


class SyncError(Exception):
    """Expected fail-closed error; message is safe to print."""


def load_watermark(state_path):
    """Returns the tz-aware datetime of the last successfully-ingested punch,
    or None if no state file exists yet (first run — sends the full device
    log once; every run after that is bounded to what's new)."""
    try:
        with open(state_path) as f:
            data = json.load(f)
        raw = data.get("last_punch_timestamp")
        return datetime.fromisoformat(raw) if raw else None
    except FileNotFoundError:
        return None
    except (json.JSONDecodeError, ValueError, TypeError) as e:
        print(f"  [!] Could not read watermark state file ({e}); treating as first run.", file=sys.stderr)
        return None


def save_watermark(state_path, ts):
    """Writes the new watermark. Call ONLY after a confirmed 2xx POST for the
    batch that ts belongs to — never advance on a failed send, so unsent
    punches are retried (and re-filtered against the OLD watermark) next
    run. Writes via a temp file + atomic rename so a crash mid-write can't
    corrupt the state file."""
    tmp_path = f"{state_path}.tmp"
    with open(tmp_path, "w") as f:
        json.dump({"last_punch_timestamp": ts.isoformat()}, f)
    os.replace(tmp_path, state_path)


def ping_healthcheck():
    """Best-effort dead-man's-switch ping after a fully-successful sync (see
    HEALTHCHECK_PING_URL in the module docstring). Never raises and never
    affects the script's exit code — this is a secondary signal, not the
    primary function. Silently skipped if the URL isn't configured."""
    ping_url = os.environ.get("HEALTHCHECK_PING_URL")
    if not ping_url:
        return
    import requests

    try:
        requests.get(ping_url, timeout=10)
    except Exception as e:
        print(f"  [!] healthchecks.io ping failed (non-fatal): {e}", file=sys.stderr)


def normalize_device_user_id(value):
    if not isinstance(value, str):
        raise SyncError("Roster deviceUserId must be a string")
    trimmed = value.strip()
    if not trimmed.isdigit() or len(trimmed) > 5:
        raise SyncError(f"Invalid roster deviceUserId: {value!r}")
    numeric = int(trimmed)
    if numeric < DEVICE_USER_ID_MIN or numeric > DEVICE_USER_ID_MAX:
        raise SyncError(f"Roster deviceUserId out of range: {value!r}")
    canonical = str(numeric)
    if trimmed != canonical:
        raise SyncError(f"Roster deviceUserId must be canonical: {value!r}")
    return canonical


def normalize_display_name(value):
    if not isinstance(value, str):
        raise SyncError("Roster displayName must be a string")
    name = " ".join(value.strip().split())
    if not name:
        raise SyncError("Roster displayName must be nonblank")
    return name


def truncate_device_name(name):
    return name[:DEVICE_NAME_MAX_LENGTH]


def derive_roster_url(ingest_url, explicit_roster_url=None):
    roster_url = explicit_roster_url or ""
    if not roster_url:
        parsed = urlsplit(ingest_url or "")
        parts = [part for part in parsed.path.split("/") if part]
        if not parsed.scheme or not parsed.netloc or not parts or parts[-1] != "ingest":
            raise SyncError("ROSTER_URL not set and INGEST_URL does not end with /ingest")
        parts[-1] = "roster"
        roster_url = urlunsplit((parsed.scheme, parsed.netloc, "/" + "/".join(parts), parsed.query, parsed.fragment))

    parsed = urlsplit(roster_url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise SyncError("ROSTER_URL must be an HTTPS URL")
    return roster_url


def validate_roster_response(data, expected_serial=DEVICE_SERIAL):
    if not isinstance(data, dict):
        raise SyncError("Roster response must be a JSON object")
    if data.get("ok") is not True:
        raise SyncError("Roster response did not return ok=true")
    response_serial = data.get("deviceSerial")
    if response_serial != expected_serial:
        raise SyncError(f"Roster device serial mismatch: got {response_serial!r}, expected {expected_serial}")
    roster = data.get("roster")
    if not isinstance(roster, list):
        raise SyncError("Roster response must include a roster list")

    entries = []
    seen_ids = set()
    for item in roster:
        if not isinstance(item, dict):
            raise SyncError("Roster entries must be JSON objects")
        device_user_id = normalize_device_user_id(item.get("deviceUserId"))
        display_name = normalize_display_name(item.get("displayName"))
        if device_user_id in seen_ids:
            raise SyncError(f"Duplicate roster deviceUserId: {device_user_id}")
        seen_ids.add(device_user_id)
        entries.append({"deviceUserId": device_user_id, "displayName": display_name})
    return entries


def fetch_roster_with_retries(roster_url, device_api_key, expected_serial=DEVICE_SERIAL):
    import requests

    headers = {"Authorization": f"Bearer {device_api_key}"}
    delay = RETRY_BACKOFF_SECONDS
    last_error = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = requests.get(roster_url, headers=headers, timeout=30)
            if resp.status_code >= 500:
                raise requests.HTTPError(f"server error {resp.status_code}: {resp.text[:300]}")
            if resp.status_code >= 400:
                raise SyncError(f"Roster request rejected ({resp.status_code}): {resp.text[:300]}")
            try:
                return validate_roster_response(resp.json(), expected_serial=expected_serial)
            except ValueError as e:
                raise SyncError(f"Roster response was not valid JSON: {e}")
        except SyncError:
            raise
        except Exception as e:
            last_error = e
            print(f"  [!] Roster GET attempt {attempt}/{MAX_RETRIES} failed: {e}")
            if attempt < MAX_RETRIES:
                time.sleep(delay)
                delay *= 2
    raise SyncError(f"All {MAX_RETRIES} roster GET attempts failed. Last error: {last_error}")


def post_with_retries(url, headers, payload):
    """POSTs the batch, retrying up to MAX_RETRIES times with backoff on any
    network failure. Returns the parsed response JSON on success, or None if
    every attempt failed (caller logs and exits non-zero — the device keeps
    buffering unread punches, so there's no need for a local disk queue)."""
    import requests

    delay = RETRY_BACKOFF_SECONDS
    last_error = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = requests.post(url, headers=headers, json=payload, timeout=30)
            if resp.status_code >= 500:
                raise requests.HTTPError(f"server error {resp.status_code}: {resp.text[:300]}")
            if resp.status_code >= 400:
                # Client errors (401/409/400) won't be fixed by retrying — fail fast.
                print(f"  [!] Ingest rejected the request ({resp.status_code}): {resp.text[:300]}", file=sys.stderr)
                return None
            return resp.json()
        except Exception as e:
            last_error = e
            print(f"  [!] POST attempt {attempt}/{MAX_RETRIES} failed: {e}")
            if attempt < MAX_RETRIES:
                time.sleep(delay)
                delay *= 2
    print(f"  [x] All {MAX_RETRIES} POST attempts failed. Last error: {last_error}", file=sys.stderr)
    return None


def user_field(user, field, default=""):
    return getattr(user, field, default)


def canonical_existing_user_id(user):
    raw = user_field(user, "user_id", "")
    if raw is None:
        return None
    text = str(raw).strip()
    if not text or not text.isdigit():
        return None
    return normalize_device_user_id(text)


def build_device_user_index(users):
    by_user_id = {}
    by_uid = {}
    for user in users or []:
        uid = user_field(user, "uid", None)
        if uid is not None:
            try:
                uid_int = int(uid)
            except (TypeError, ValueError):
                raise SyncError(f"Ambiguous device user with non-numeric uid: {uid!r}")
            if uid_int in by_uid:
                raise SyncError(f"Duplicate device uid on clock: {uid_int}")
            by_uid[uid_int] = user

        user_id = canonical_existing_user_id(user)
        if user_id is None:
            continue
        if user_id in by_user_id:
            raise SyncError(f"Duplicate device user_id on clock: {user_id}")
        by_user_id[user_id] = user
    return by_user_id, by_uid


def plan_roster_user_sync(roster, existing_users):
    by_user_id, by_uid = build_device_user_index(existing_users)
    actions = []

    for entry in roster:
        device_user_id = entry["deviceUserId"]
        target_uid = int(device_user_id)
        target_name = truncate_device_name(entry["displayName"])
        existing = by_user_id.get(device_user_id)
        uid_owner = by_uid.get(target_uid)

        if existing is None:
            if uid_owner is not None:
                owner_user_id = user_field(uid_owner, "user_id", "")
                raise SyncError(
                    f"UID collision on clock: roster {device_user_id} needs uid {target_uid}, "
                    f"already used by user_id {owner_user_id!r}"
                )
            actions.append(
                {
                    "type": "create",
                    "uid": target_uid,
                    "name": target_name,
                    "privilege": ORDINARY_PRIVILEGE,
                    "password": "",
                    "group_id": "",
                    "user_id": device_user_id,
                    "card": 0,
                }
            )
            continue

        existing_uid = int(user_field(existing, "uid", -1))
        if existing_uid != target_uid:
            raise SyncError(
                f"user_id collision on clock: roster {device_user_id} maps to uid {target_uid}, "
                f"but clock has uid {existing_uid}"
            )
        if uid_owner is not existing:
            raise SyncError(f"Ambiguous uid/user_id mapping on clock for {device_user_id}")

        current_name = user_field(existing, "name", "") or ""
        if current_name == target_name:
            actions.append({"type": "noop", "user_id": device_user_id})
            continue

        actions.append(
            {
                "type": "rename",
                "uid": existing_uid,
                "name": target_name,
                "privilege": user_field(existing, "privilege", ORDINARY_PRIVILEGE),
                "password": user_field(existing, "password", ""),
                "group_id": user_field(existing, "group_id", ""),
                "user_id": user_field(existing, "user_id", device_user_id),
                "card": user_field(existing, "card", 0),
            }
        )
    return actions


def apply_user_sync_plan(conn, actions, dry_run=False):
    creates = sum(1 for action in actions if action["type"] == "create")
    renames = sum(1 for action in actions if action["type"] == "rename")
    noops = sum(1 for action in actions if action["type"] == "noop")
    print(f"Roster user sync plan: create={creates} rename={renames} no-op={noops}")
    for action in actions:
        if action["type"] == "noop":
            continue
        prefix = "[dry-run] Would" if dry_run else "Will"
        print(f"  {prefix} {action['type']} device user {action['user_id']} as {action['name']!r}")
        if dry_run:
            continue
        conn.set_user(
            uid=action["uid"],
            name=action["name"],
            privilege=action["privilege"],
            password=action["password"],
            group_id=action["group_id"],
            user_id=action["user_id"],
            card=action["card"],
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    ingest_url = os.environ.get("INGEST_URL")
    device_api_key = os.environ.get("DEVICE_API_KEY")
    roster_url_env = os.environ.get("ROSTER_URL")
    state_path = os.environ.get("SYNC_STATE_PATH", DEFAULT_STATE_PATH)
    if not ingest_url:
        print("INGEST_URL not set. Export it or add a .env file.", file=sys.stderr)
        sys.exit(1)
    if not device_api_key:
        print("DEVICE_API_KEY not set. Export it or add a .env file.", file=sys.stderr)
        sys.exit(1)

    try:
        roster_url = derive_roster_url(ingest_url, roster_url_env)
        print(f"Fetching roster from {roster_url} ...")
        roster = fetch_roster_with_retries(roster_url, device_api_key)
        print(f"Validated {len(roster)} roster entr{'y' if len(roster) == 1 else 'ies'}.")
    except SyncError as e:
        print(f"Roster sync failed before reading punches: {e}", file=sys.stderr)
        print("Device punch logs were not read or changed; this run will retry on the next schedule.", file=sys.stderr)
        sys.exit(1)

    if args.dry_run:
        print("[dry-run] Mutations, ingest POSTs, watermark writes, and healthcheck pings are disabled.")

    watermark = load_watermark(state_path)
    if watermark:
        print(f"Watermark: only sending punches after {watermark.isoformat()} ({state_path})")
    else:
        print(f"No watermark at {state_path} yet — this looks like the first run; sending the full device log once.")

    from zk import ZK

    print(f"Connecting to NGTeco K4 at {DEVICE_IP}:{DEVICE_PORT} ...")
    zk = ZK(DEVICE_IP, port=DEVICE_PORT, timeout=10, password=0, ommit_ping=True)
    conn = zk.connect()
    device_time_iso = None
    try:
        serial = conn.get_serialnumber()
        if serial != DEVICE_SERIAL:
            raise SyncError(
                f"Connected device serial mismatch: got {serial!r}, expected {DEVICE_SERIAL}; refusing roster mutation"
            )

        existing_users = conn.get_users() or []
        actions = plan_roster_user_sync(roster, existing_users)
        apply_user_sync_plan(conn, actions, dry_run=args.dry_run)

        # Drift check + auto-correct: device time must match Guyana wall-clock.
        # The clock shipped ~1h behind (wrong TZ default) and set_time is
        # confirmed working on this K4 firmware, so rather than just warning,
        # every sync re-verifies and fixes drift > 2 min. Punches recorded
        # BEFORE a correction keep their (wrong) recorded time — hence the
        # loud log, so a human knows to review that window. The (possibly
        # just-corrected) device time is also sent to the server as
        # `deviceTime` so it can independently track drift server-side.
        try:
            device_now = conn.get_time().replace(tzinfo=GUYANA_TZ)
            drift = (device_now - datetime.now(GUYANA_TZ)).total_seconds()
            if abs(drift) > 120:
                print(f"  [!] Device clock was {drift:+.0f}s off Guyana time "
                      f"(device said {device_now:%Y-%m-%d %H:%M:%S}). Correcting now — "
                      f"REVIEW punches recorded before this sync, their times may be wrong.")
                if args.dry_run:
                    print("  [dry-run] Would correct device clock; leaving it untouched.")
                else:
                    conn.set_time(datetime.now(GUYANA_TZ).replace(tzinfo=None, microsecond=0))
                    device_now = conn.get_time().replace(tzinfo=GUYANA_TZ)
                    print(f"  [+] Device clock set to {device_now:%Y-%m-%d %H:%M:%S} (Guyana).")
            device_time_iso = device_now.isoformat()
        except Exception as e:
            print(f"  [!] Could not verify/correct device time: {e}")
            device_time_iso = datetime.now(GUYANA_TZ).isoformat()

        records = conn.get_attendance() or []
        print(f"Retrieved {len(records)} punch records from device.")
    except SyncError as e:
        print(f"Roster user sync failed before reading punches: {e}", file=sys.stderr)
        print("Device punch logs were not read or changed; this run will retry on the next schedule.", file=sys.stderr)
        sys.exit(1)
    finally:
        conn.disconnect()

    # (timestamp, payload) pairs, filtered against the watermark so we only
    # ever re-send what hasn't already made it to the server — the device's
    # own onboard log is left completely alone (never trimmed/cleared here).
    punch_records = []
    skipped_old = 0
    for r in records:
        ts = r.timestamp
        if ts.tzinfo is None:
            # Device local time -> Guyana-aware. NEVER tag as UTC: that
            # would shift every punch +4h and misclassify late-evening
            # punches into the next day (wrong weekend/OT buckets).
            ts = ts.replace(tzinfo=GUYANA_TZ)
        if watermark is not None and ts <= watermark:
            skipped_old += 1
            continue
        punch_records.append(
            (
                ts,
                {
                    "deviceUserId": str(r.user_id),
                    "timestamp": ts.isoformat(),
                    "punchState": r.punch,
                    "verifyMethod": r.status,
                },
            )
        )

    # Sorted ascending so batches are sent in chronological order and each
    # batch's max timestamp is a valid, monotonically-advancing watermark —
    # important if a run is interrupted partway through a large backlog.
    punch_records.sort(key=lambda item: item[0])
    if skipped_old:
        print(f"Skipping {skipped_old} punch(es) at/before the watermark (already ingested in a previous run).")

    if args.dry_run:
        total = len(punch_records)
        n_batches = max(1, (total + BATCH_SIZE - 1) // BATCH_SIZE)
        print(
            f"[dry-run] Would POST {total} new punch(es) to "
            f"{ingest_url or '(INGEST_URL not set)'} across {n_batches} batch(es) of up to {BATCH_SIZE}. Sample:"
        )
        for _, p in punch_records[:5]:
            print(f"  {p}")
        return

    # ALWAYS send at least one request, even with zero new punches — an
    # empty-punches POST is the heartbeat the server uses for online/stale
    # status and clock-drift tracking. Do not skip it just because there's
    # nothing new to report.
    batches = (
        [punch_records[i : i + BATCH_SIZE] for i in range(0, len(punch_records), BATCH_SIZE)]
        if punch_records
        else [[]]
    )

    headers = {"Authorization": f"Bearer {device_api_key}"}
    total_inserted = 0
    total_duplicates = 0
    unlinked_ids = set()
    server_time = None

    for batch_num, batch in enumerate(batches, start=1):
        payload = {
            "deviceSerial": DEVICE_SERIAL,
            "deviceTime": device_time_iso,
            "punches": [p for _, p in batch],
        }
        print(f"Posting batch {batch_num}/{len(batches)} ({len(batch)} punch(es)) ...")
        result = post_with_retries(ingest_url, headers, payload)

        if result is None:
            print(
                f"Sync failed on batch {batch_num}/{len(batches)} — watermark stays at "
                f"{watermark.isoformat() if watermark else 'unset'}; this batch and any after it retry next run.",
                file=sys.stderr,
            )
            sys.exit(1)

        if batch:
            watermark = batch[-1][0]
            save_watermark(state_path, watermark)

        total_inserted += result.get("inserted") or 0
        total_duplicates += result.get("duplicates") or 0
        unlinked_ids.update(result.get("unlinkedDeviceUserIds") or [])
        server_time = result.get("serverTime")

    # Only reached once every batch (including a zero-punch heartbeat) has
    # gotten a confirmed 2xx — a partial failure exits above without pinging.
    ping_healthcheck()

    print(
        f"Done. inserted={total_inserted} duplicates={total_duplicates} "
        f"unlinkedDeviceUserIds={sorted(unlinked_ids)} serverTime={server_time}"
    )


if __name__ == "__main__":
    main()
'@
    $files['updater.py'] = @'
#!/usr/bin/env python3
"""
GitHub-pull self-updater for the on-site NGTeco sync agent (Windows).
=======================================================================
Keeps sync_ngteco_punches.py in sync with the canonical copy in the
bettencourt-hr-platform repo on GitHub, so a future fix pushed to
scripts/sync_ngteco_punches.py on `main` lands on the Windows PC within
one Task Scheduler cycle -- no on-site visit or RDP session needed to
redeploy a change.

Runs BEFORE sync_ngteco_punches.py on every cycle (see run_sync.ps1). A
failed check (bad token, network hiccup, GitHub down) never blocks the
sync itself -- it logs a warning and leaves the existing local copy in
place, the same fail-open pattern HEALTHCHECK_PING_URL uses in
sync_ngteco_punches.py.

Env vars (.env, same file as sync_ngteco_punches.py):
    GITHUB_REPO      - default kareemschultz/bettencourt-hr-platform
    GITHUB_BRANCH    - default main
    GITHUB_FILE_PATH - default scripts/sync_ngteco_punches.py
    GITHUB_PAT       - fine-grained PAT, Contents:Read-only, scoped to
                       GITHUB_REPO only (repo is private). Auto-update is
                       simply skipped if unset -- not an error.

State:
    .installed_sha next to the managed script -- the GitHub blob sha of
    the version currently installed. Compared against GitHub's current
    blob sha; only downloads + replaces when they differ.
"""
import base64
import json
import os
import sys
import urllib.request
import urllib.error

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

GITHUB_REPO = os.environ.get("GITHUB_REPO", "kareemschultz/bettencourt-hr-platform")
GITHUB_BRANCH = os.environ.get("GITHUB_BRANCH", "main")
GITHUB_FILE_PATH = os.environ.get("GITHUB_FILE_PATH", "scripts/sync_ngteco_punches.py")
GITHUB_PAT = os.environ.get("GITHUB_PAT")

MANAGED_SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sync_ngteco_punches.py")
SHA_STATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".installed_sha")


def load_installed_sha():
    try:
        with open(SHA_STATE_PATH) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def save_installed_sha(sha):
    tmp_path = f"{SHA_STATE_PATH}.tmp"
    with open(tmp_path, "w") as f:
        f.write(sha)
    os.replace(tmp_path, SHA_STATE_PATH)


def main():
    if not GITHUB_PAT:
        print("[updater] GITHUB_PAT not set -- skipping update check (auto-update disabled until configured).")
        return

    url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{GITHUB_FILE_PATH}?ref={GITHUB_BRANCH}"
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {GITHUB_PAT}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "bettencourt-hr-ngteco-agent",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        print(f"[updater] GitHub API check failed ({e.code}): {e.reason}. Keeping existing local script.", file=sys.stderr)
        return
    except Exception as e:
        print(f"[updater] GitHub API check failed: {e}. Keeping existing local script.", file=sys.stderr)
        return

    remote_sha = data.get("sha")
    if not remote_sha or "content" not in data:
        print("[updater] Unexpected GitHub API response shape -- keeping existing local script.", file=sys.stderr)
        return

    installed_sha = load_installed_sha()
    if installed_sha == remote_sha:
        print(f"[updater] Up to date (sha {remote_sha[:8]}).")
        return

    print(
        f"[updater] Update available: "
        f"{installed_sha[:8] if installed_sha else 'none'} -> {remote_sha[:8]}. "
        f"Pulling from GitHub ({GITHUB_BRANCH})..."
    )

    try:
        content = base64.b64decode(data["content"])
        tmp_path = f"{MANAGED_SCRIPT_PATH}.tmp"
        with open(tmp_path, "wb") as f:
            f.write(content)
        os.replace(tmp_path, MANAGED_SCRIPT_PATH)
        save_installed_sha(remote_sha)
    except Exception as e:
        # Matches the fail-open contract in the module docstring: a disk-full,
        # AV-lock, or permission error here must never raise past this
        # function -- the existing local script keeps running untouched, and
        # the next cycle just retries the same update.
        print(f"[updater] Failed to apply update: {e}. Keeping existing local script.", file=sys.stderr)
        return

    print(f"[updater] Updated sync_ngteco_punches.py to sha {remote_sha[:8]}.")


if __name__ == "__main__":
    main()
'@
    $files['uninstall.ps1'] = @'
<#
.SYNOPSIS
    Removes the Bettencourt HR NGTeco sync Task Scheduler task. Does not
    delete this folder, its venv, or .env -- remove those manually for a
    full wipe.
#>
param(
    [string]$TaskName = "BettencourtHR-NGTecoSync"
)
$ErrorActionPreference = "Stop"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
Write-Host "Removed scheduled task '$TaskName'."
'@
    $files['run_sync.ps1'] = @'
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$python = Join-Path $here 'venv\Scripts\python.exe'
$log = Join-Path $here 'agent.log'
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 5MB)) {
    Move-Item -Force $log (Join-Path $here 'agent.log.1')
}
function Log([string]$message) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $message
    $line | Out-File -FilePath $log -Append -Encoding utf8
}
Log '=== Attendance sync starting ==='
if (-not (Test-Path $python)) { Log '[x] Python venv missing; reinstall agent.'; exit 1 }
try {
    $updateOutput = & $python (Join-Path $here 'updater.py') 2>&1
    $updateOutput | Out-File -FilePath $log -Append -Encoding utf8
} catch {
    Log ('[!] Updater failed; keeping existing script: ' + $_)
}
try {
    $output = & $python (Join-Path $here 'sync_ngteco_punches.py') 2>&1
    $code = $LASTEXITCODE
    $output | Out-File -FilePath $log -Append -Encoding utf8
    if ($code -ne 0) {
        Log ('[!] Sync failed with exit ' + $code + '; retry on next cycle.')
        exit 1
    }
    Log '=== Attendance sync successful ==='
    exit 0
} catch {
    Log ('[!] Sync exception: ' + $_)
    exit 1
}
'@

    foreach ($name in $files.Keys) {
        [IO.File]::WriteAllText((Join-Path $installDir $name),[string]$files[$name],$utf8)
        Write-Host ('Wrote ' + $name)
    }
    $configLines = @(
        'INGEST_URL=https://hr.bettencourtgy.com/api/attendance/ingest',
        ('DEVICE_API_KEY=' + $apiKey),
        ('NGTECO_K4_IP=' + $clockIP),
        'NGTECO_K4_PORT=4370',
        'GITHUB_REPO=kareemschultz/bettencourt-hr-platform',
        'GITHUB_BRANCH=main',
        'GITHUB_FILE_PATH=scripts/sync_ngteco_punches.py'
    )
    if ($healthUrl) { $configLines += ('HEALTHCHECK_PING_URL=' + $healthUrl) }
    [IO.File]::WriteAllText($cfgPath,(($configLines -join [Environment]::NewLine) + [Environment]::NewLine),$utf8)
    $apiKey = $null
    $healthUrl = $null
    Step 'Restricting local filesystem permissions'
    & icacls.exe $installDir '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to secure the agent folder.' }
    Step 'Installing Python dependencies'
    $venv = Join-Path $installDir 'venv'
    $venvPython = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        & $pyExe @pyArgs -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create Python virtual environment.' }
    }
    & $venvPython -m pip install --disable-pip-version-check pyzk requests python-dotenv
    if ($LASTEXITCODE -ne 0) { throw 'Python dependency installation failed. Restore Internet access and rerun.' }
    Step 'Registering Windows automatic sync task'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $installDir 'run_sync.ps1'))
    $fiveMin = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $boot = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    $runAs = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($fiveMin,$boot) -Settings $settings -Principal $runAs -Force -Description 'NGTeco K4 roster and attendance punches to Bettencourt HR; retries after outages.' | Out-Null
    Step 'Checking connectivity and Windows time'
    try {
        $ntpStatus = & w32tm.exe /query /status 2>&1
        if (($LASTEXITCODE -ne 0) -or (($ntpStatus -join ' ') -match 'Local CMOS Clock|Free-running System Clock')) {
            Write-Warning 'PC time source is not verified. Configure Windows time synchronization before trusting clock correction.'
        } else { Write-Host 'Windows time service responded.' }
    } catch { Write-Warning 'Could not confirm Windows time synchronization.' }
    $tcp = New-Object Net.Sockets.TcpClient
    $reachable = $false
    try {
        $connect = $tcp.ConnectAsync($clockIP,4370)
        $reachable = $connect.Wait(3000) -and $tcp.Connected
    } catch {}
    finally { $tcp.Close() }
    if ($reachable) { Write-Host ('Clock is reachable: ' + $clockIP + ':4370') }
    else { Write-Warning ('Clock offline at ' + $clockIP + ':4370. Task will retry every 5 minutes.') }
    Step 'Running initial sync'
    & (Join-Path $installDir 'run_sync.ps1')
    $firstResult = $LASTEXITCODE
    $logPath = Join-Path $installDir 'agent.log'
    if (Test-Path $logPath) { Get-Content $logPath -Tail 20 }
    if ($firstResult -ne 0) {
        Write-Warning 'Installed and scheduled, but first sync failed. Check log; it will retry on its schedule.'
    } else { Write-Host 'Initial sync succeeded.' -ForegroundColor Green }
    Write-Host ''
    Write-Host ('Installed at: ' + $installDir)
    Write-Host ('Scheduled task: ' + $taskName + ' (startup and every 5 minutes)')
    Write-Host ('Log: ' + $logPath)
    Write-Host 'Only punches retained by the clock can be recovered after an outage.'
    Write-Host 'Clock time corrections apply to future records; old wrong-time punches require review.'
    Write-Host 'Automatic GitHub code updates are disabled by default for security.'
    exit 0
} catch {
    Write-Host ('SETUP FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'The installer does not erase attendance punches from the physical clock.'
    exit 1
}
