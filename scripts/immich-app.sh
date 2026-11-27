#!/usr/bin/env bash
# Start / stop / update Immich locally with data-safe upgrades and configurable backups.
# Design: docs/superpowers/specs/2026-08-16-immich-app-lifecycle-design.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG_FILE="${IMMICH_APP_CONFIG:-$ROOT/scripts/immich-app.env}"
SYNC_SCRIPT="$ROOT/scripts/sync-upstream.sh"

# Defaults (overridden by config / env)
BACKUP_DIR="${BACKUP_DIR:-$ROOT/../immich-backups}"
BACKUP_INTERVAL_DAYS="${BACKUP_INTERVAL_DAYS:-7}"
BACKUP_KEEP="${BACKUP_KEEP:-4}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dev.yml}"
ENV_FILE="${ENV_FILE:-docker/.env}"
UPDATE_SYNC_ON_UPDATE="${UPDATE_SYNC_ON_UPDATE:-false}"

usage() {
  cat <<'EOF'
Usage: scripts/immich-app.sh <command> [options]

Commands:
  start                 Start Immich in the background
  stop                  Stop containers (keeps all data)
  down                  Remove containers (keeps volumes/bind mounts; never uses -v)
  status                Show stack, data paths, and backup status
  backup                Create a backup now
  backup --if-due       Backup only if last one is older than BACKUP_INTERVAL_DAYS
  update                Compare host vs latest release; upgrade pin+images if newer
  schedule-hint         Print cron / launchd examples for weekly backups
  help                  Show this help

Update options:
  --check               Compare versions only (no backup, pin change, pull, or recreate)
  --sync / --no-sync    Force or skip git sync with upstream (default: skip)
  --backup / --no-backup Force or skip pre-update backup
  --rebase              When syncing, rebase instead of merge

Config:
  Copy scripts/immich-app.env.example → scripts/immich-app.env
  Or set IMMICH_APP_CONFIG=/path/to/file
EOF
}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "warning: $*" >&2; }

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$CONFIG_FILE"
    set +a
  fi

  # Resolve relative backup dir against repo root
  if [[ "$BACKUP_DIR" != /* ]]; then
    BACKUP_DIR="$ROOT/$BACKUP_DIR"
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
  docker info >/dev/null 2>&1 || die "docker is not running (start Docker Desktop)"
}

ensure_env_file() {
  if [[ ! -f "$ROOT/$ENV_FILE" ]]; then
    info "creating $ENV_FILE from docker/example.env"
    cp "$ROOT/docker/example.env" "$ROOT/$ENV_FILE"
  fi
  mkdir -p "$ROOT/docker/library/photos" "$ROOT/docker/library/postgres"
}

# Load KEY=value from Immich .env without executing it as shell (values may be quoted).
env_get() {
  local key="$1" file="$ROOT/$ENV_FILE" line value
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

normalize_version() {
  local raw="${1:-}"
  if [[ "$raw" =~ \"major\":([0-9]+)[^0-9]+\"minor\":([0-9]+)[^0-9]+\"patch\":([0-9]+) ]]; then
    printf 'v%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  raw="${raw#v}"
  if [[ "$raw" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    printf 'v%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

# Exit 0 if a >= b, 1 if a < b, 2 if either unparseable.
version_cmp() {
  local a b
  a="$(normalize_version "$1")" || return 2
  b="$(normalize_version "$2")" || return 2
  local IFS=.
  # shellcheck disable=SC2086
  set -- ${a#v} ${b#v}
  local a0=$1 a1=$2 a2=$3 b0=$4 b1=$5 b2=$6
  if (( a0 > b0 || (a0 == b0 && a1 > b1) || (a0 == b0 && a1 == b1 && a2 >= b2) )); then
    return 0
  fi
  return 1
}

host_immich_version() {
  local body pin
  body="$(curl -sf --connect-timeout 2 --max-time 5 http://127.0.0.1:2283/api/server/version 2>/dev/null || true)"
  if pin="$(normalize_version "$body")"; then
    printf '%s' "$pin"
    return 0
  fi
  pin="$(env_get IMMICH_VERSION || true)"
  normalize_version "$pin"
}

latest_immich_version() {
  local json tag
  json="$(curl -sf --connect-timeout 5 --max-time 15 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: immich-app.sh' \
    https://api.github.com/repos/immich-app/immich/releases/latest)" \
    || die "could not fetch latest Immich release from GitHub"
  tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$tag" ]] || die "GitHub latest release missing tag_name"
  normalize_version "$tag" || die "unparseable latest tag: $tag"
}

print_version_comparison() {
  local host="$1" latest="$2" status="$3"
  info "host: ${host:-unknown}  latest: ${latest}  status: ${status}"
}

set_immich_version() {
  local tag="$1" file="$ROOT/$ENV_FILE"
  [[ -f "$file" ]] || die "missing $file"
  if grep -qE '^IMMICH_VERSION=' "$file"; then
    local tmp
    tmp="$(mktemp)"
    sed "s/^IMMICH_VERSION=.*/IMMICH_VERSION=${tag}/" "$file" >"$tmp"
    mv "$tmp" "$file"
  else
    printf '\nIMMICH_VERSION=%s\n' "$tag" >>"$file"
  fi
}

upload_location() {
  local loc
  loc="$(env_get UPLOAD_LOCATION || true)"
  loc="${loc:-./library}"
  if [[ "$loc" != /* ]]; then
    # Paths in docker/.env are relative to docker/
    loc="$ROOT/docker/$loc"
  fi
  # normalize
  (cd "$(dirname "$loc")" && echo "$(pwd)/$(basename "$loc")")
}

compose() {
  (
    cd "$ROOT/docker"
    local args=(-f "./$COMPOSE_FILE")
    # Explicit -f disables automatic override loading; include it when present.
    if [[ -f ./docker-compose.override.yml ]]; then
      args+=(-f ./docker-compose.override.yml)
    fi
    COMPOSE_BAKE=true docker compose "${args[@]}" --env-file "$(basename "$ENV_FILE")" "$@"
  )
}

stack_running() {
  local ids
  ids="$(compose ps -q 2>/dev/null || true)"
  [[ -n "$ids" ]]
}

postgres_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'immich_postgres'
}

last_backup_dir() {
  [[ -d "$BACKUP_DIR" ]] || return 1
  # Prefer marker file; fall back to newest timestamp dir
  local latest
  latest="$(ls -1dt "$BACKUP_DIR"/20* 2>/dev/null | head -n1 || true)"
  [[ -n "$latest" ]] || return 1
  echo "$latest"
}

backup_age_days() {
  local latest mtime now
  latest="$(last_backup_dir)" || return 1
  if [[ -f "$latest/.immich-backup-complete" ]]; then
    mtime="$(stat -f %m "$latest/.immich-backup-complete" 2>/dev/null || stat -c %Y "$latest/.immich-backup-complete")"
  else
    mtime="$(stat -f %m "$latest" 2>/dev/null || stat -c %Y "$latest")"
  fi
  now="$(date +%s)"
  echo $(( (now - mtime) / 86400 ))
}

prune_backups() {
  local keep="${BACKUP_KEEP:-4}"
  [[ "$keep" =~ ^[0-9]+$ ]] || return 0
  [[ -d "$BACKUP_DIR" ]] || return 0
  local i=0 dir
  # Portable on macOS Bash 3.2 (no mapfile)
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    i=$((i + 1))
    if [[ "$i" -gt "$keep" ]]; then
      info "pruning old backup: $dir"
      rm -rf "$dir"
    fi
  done < <(ls -1dt "$BACKUP_DIR"/20* 2>/dev/null || true)
}

build_plugins() {
  if command -v mise >/dev/null 2>&1; then
    info "building plugins (required by Immich server)"
    (cd "$ROOT" && mise run plugins)
  else
    warn "mise not found; skipping plugins build — server may fail until you run: mise run plugins"
  fi
}

LAN_PROXY_APP="$ROOT/scripts/ImmichLanProxy.app"
LAN_PROXY_BIN="$LAN_PROXY_APP/Contents/MacOS/ImmichLanProxy"
LAN_PROXY_PY="$ROOT/scripts/immich-lan-proxy.py"
LAN_PROXY_PID="$ROOT/scripts/.immich-lan-proxy.pid"

lan_ip() {
  ipconfig getifaddr en7 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || true
}

ensure_lan_proxy_bin() {
  if [[ -x "$LAN_PROXY_BIN" ]]; then
    return 0
  fi
  if [[ -x "$ROOT/scripts/build-immich-lan-proxy.sh" ]] && command -v go >/dev/null 2>&1; then
    info "building ImmichLanProxy.app (dedicated firewall allowlist binary)"
    "$ROOT/scripts/build-immich-lan-proxy.sh"
  fi
  [[ -x "$LAN_PROXY_BIN" ]]
}

stop_lan_proxy() {
  if [[ -f "$LAN_PROXY_PID" ]]; then
    local pid
    pid="$(cat "$LAN_PROXY_PID" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      info "stopping LAN proxy (pid $pid)"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$LAN_PROXY_PID"
  fi
  pkill -f 'ImmichLanProxy' 2>/dev/null || true
  pkill -f 'immich-lan-proxy.py' 2>/dev/null || true
}

lan_proxy_running() {
  if [[ -f "$LAN_PROXY_PID" ]]; then
    local pid
    pid="$(cat "$LAN_PROXY_PID" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  pgrep -f 'ImmichLanProxy|immich-lan-proxy.py' >/dev/null 2>&1
}

phone_server_url() {
  local lip
  lip="$(lan_ip)"
  [[ -n "$lip" ]] && printf 'http://%s:2283' "$lip"
}

# ok | waiting | proxy_down | proxy_broken | no_lan_ip | unreachable
check_phone_access() {
  local lip body
  lip="$(lan_ip)"
  if [[ -z "$lip" ]]; then
    echo "no_lan_ip"
    return
  fi
  if ! lan_proxy_running; then
    echo "proxy_down"
    return
  fi
  body="$(curl -sf --connect-timeout 3 --max-time 5 "http://${lip}:2283/api/server/version" 2>/dev/null || true)"
  if [[ -n "$body" ]] && echo "$body" | grep -q '"major"'; then
    echo "ok"
    return
  fi
  # Distinguish a broken proxy from a server that is still booting.
  body="$(curl -sf --connect-timeout 2 --max-time 5 http://127.0.0.1:2283/api/server/version 2>/dev/null || true)"
  if [[ -n "$body" ]] && echo "$body" | grep -q '"major"'; then
    echo "proxy_broken"
    return
  fi
  body="$(curl -sf --connect-timeout 2 --max-time 5 http://127.0.0.1:2283/api/server/ping 2>/dev/null || true)"
  if [[ -n "$body" ]]; then
    echo "waiting"
    return
  fi
  echo "server_starting"
}

phone_access_status_line() {
  local state url
  state="$(check_phone_access)"
  url="$(phone_server_url)"
  case "$state" in
    ok)
      echo "phone access: OK — mobile URL ${url} (port 2283, not 3000)"
      ;;
    no_lan_ip)
      echo "phone access: unknown — no LAN IP detected (connect to Wi-Fi and re-check)"
      ;;
    proxy_down)
      echo "phone access: BROKEN — LAN proxy not running (run: scripts/immich-app.sh start)"
      ;;
    proxy_broken)
      echo "phone access: BROKEN — LAN proxy not forwarding (run: scripts/immich-app.sh stop && scripts/immich-app.sh start)"
      ;;
    waiting|server_starting)
      if [[ -n "$url" ]]; then
        echo "phone access: waiting — API still starting; use ${url} once ready"
      else
        echo "phone access: waiting — API still starting"
      fi
      ;;
    *)
      if [[ -n "$url" ]]; then
        echo "phone access: BROKEN — cannot reach ${url}/api/server/version"
      else
        echo "phone access: BROKEN — cannot reach API via LAN"
      fi
      ;;
  esac
}

verify_phone_access() {
  local state url
  state="$(check_phone_access)"
  if [[ "$state" == "ok" ]]; then
    url="$(phone_server_url)"
    info "phone access check: OK (${url})"
    return 0
  fi
  if [[ "$state" == "proxy_broken" || "$state" == "proxy_down" ]]; then
    warn "phone access check failed ($state) — restarting LAN proxy"
    start_lan_proxy
    sleep 1
    state="$(check_phone_access)"
    if [[ "$state" == "ok" ]]; then
      url="$(phone_server_url)"
      info "phone access check: OK after proxy restart (${url})"
      return 0
    fi
  fi
  url="$(phone_server_url)"
  case "$state" in
    server_starting|waiting)
      warn "phone access check: API still starting — mobile may fail until the server is ready"
      [[ -n "$url" ]] && warn "then use ${url} in the mobile app (port 2283, not 3000)"
      ;;
    no_lan_ip)
      warn "phone access check: no LAN IP detected — connect to Wi-Fi and run: scripts/immich-app.sh status"
      ;;
    *)
      warn "phone access check: FAILED ($state)"
      warn "mobile app needs port 2283 (not 3000). Try: scripts/immich-app.sh stop && scripts/immich-app.sh start"
      [[ -n "$url" ]] && warn "expected URL: ${url}"
      ;;
  esac
  return 1
}

start_lan_proxy() {
  if [[ "${LAN_PROXY_ENABLED:-true}" != "true" ]]; then
    stop_lan_proxy
    info "LAN proxy disabled (LAN_PROXY_ENABLED=${LAN_PROXY_ENABLED}); devices use the home-gateway (Traefik) instead"
    return 0
  fi
  stop_lan_proxy
  local lip
  lip="$(lan_ip)"

  if ensure_lan_proxy_bin; then
    info "starting ImmichLanProxy.app (phone :2283 → localhost:2283)"
    info "Firewall: allow ONLY \"Immich LAN Proxy\" / ImmichLanProxy — not all of Python"
    "$LAN_PROXY_BIN" -daemon -pid-file "$LAN_PROXY_PID"
  elif [[ -f "$LAN_PROXY_PY" ]]; then
    warn "ImmichLanProxy.app missing; falling back to Python (less ideal for Firewall)"
    local py
    py="/usr/bin/python3"
    [[ -x "$py" ]] || py="$(command -v python3)"
    [[ -n "$py" ]] || die "python3 not found and ImmichLanProxy.app not built"
    "$py" "$LAN_PROXY_PY" --daemon --pid-file "$LAN_PROXY_PID"
  else
    die "missing LAN proxy (build with scripts/build-immich-lan-proxy.sh)"
  fi

  sleep 0.8
  if [[ -n "$lip" ]]; then
    info "phone Server URL: http://${lip}:2283"
    if ! python3 -c "import urllib.request; urllib.request.urlopen('http://${lip}:2283/api/server/ping', timeout=5)" >/dev/null 2>&1; then
      warn "LAN proxy started but http://${lip}:2283 is not reachable"
      warn "1) System Settings → Network → Firewall: turn OFF \"Block all incoming\""
      warn "2) Options → allow ImmichLanProxy / Immich LAN Proxy (incoming)"
      warn "3) If Little Snitch is on, allow ImmichLanProxy on port 2283"
    fi
  else
    info "phone Server URL: http://<your-mac-lan-ip>:2283"
  fi
}

cmd_start() {
  require_docker
  ensure_env_file
  build_plugins
  info "starting Immich (detached)"
  compose up -d --remove-orphans --build
  start_lan_proxy
  verify_phone_access || true
  info "web UI: http://localhost:3000  (API localhost: http://127.0.0.1:2283)"
  info "first boot can take several minutes while containers install deps"
  compose ps
}

cmd_stop() {
  require_docker
  ensure_env_file
  stop_lan_proxy
  info "stopping Immich containers (data retained)"
  compose stop
}

cmd_down() {
  require_docker
  ensure_env_file
  stop_lan_proxy
  info "removing Immich containers (no -v; data retained)"
  compose down --remove-orphans
}

cmd_status() {
  require_docker
  ensure_env_file
  local upload
  upload="$(upload_location)"

  echo "config:     $CONFIG_FILE$([ -f "$CONFIG_FILE" ] && echo '' || echo ' (missing — using defaults)')"
  echo "compose:    docker/$COMPOSE_FILE"
  echo "env:        $ENV_FILE"
  echo "upload:     $upload"
  echo "photos:     $upload/photos"
  echo "postgres:   $upload/postgres"
  echo "backups:    $BACKUP_DIR"
  echo "interval:   every $BACKUP_INTERVAL_DAYS day(s), keep $BACKUP_KEEP"
  echo

  if stack_running; then
    compose ps
  else
    echo "stack:      not running"
  fi
  echo
  echo "$(phone_access_status_line)"
  echo

  local latest age
  if latest="$(last_backup_dir)"; then
    age="$(backup_age_days || echo '?')"
    echo "last backup: $latest (${age} day(s) ago)"
  else
    echo "last backup: none"
  fi
}

do_backup() {
  local if_due=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --if-due) if_due=true ;;
      *) die "unknown backup option: $1" ;;
    esac
    shift
  done

  ensure_env_file
  local upload
  upload="$(upload_location)"

  if [[ "$if_due" == true ]]; then
    local age
    if age="$(backup_age_days 2>/dev/null)"; then
      if [[ "$age" -lt "$BACKUP_INTERVAL_DAYS" ]]; then
        info "backup not due (last was ${age}d ago; interval ${BACKUP_INTERVAL_DAYS}d)"
        return 0
      fi
    fi
  fi

  require_docker
  mkdir -p "$BACKUP_DIR"
  local stamp dest was_running=false
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="$BACKUP_DIR/$stamp"
  mkdir -p "$dest"

  info "backing up to $dest"

  if stack_running; then
    was_running=true
  fi

  # Prefer logical DB dump while Postgres is up; otherwise copy data dir after stop.
  if postgres_running; then
    info "dumping database (pg_dumpall)"
    docker exec immich_postgres pg_dumpall -U "$(env_get DB_USERNAME || echo postgres)" \
      >"$dest/postgres.sql"
    info "copying photos"
    mkdir -p "$dest/photos"
    if [[ -d "$upload/photos" ]]; then
      rsync -a "$upload/photos/" "$dest/photos/" 2>/dev/null || cp -a "$upload/photos/." "$dest/photos/"
    fi
  else
    info "postgres not running — stopping stack briefly for consistent filesystem copy"
    if [[ "$was_running" == true ]]; then
      compose stop
    fi
    if [[ -d "$upload" ]]; then
      rsync -a "$upload/" "$dest/upload/" 2>/dev/null || cp -a "$upload/." "$dest/upload/"
    else
      warn "upload location missing: $upload"
    fi
  fi

  if [[ -f "$ROOT/$ENV_FILE" ]]; then
    cp "$ROOT/$ENV_FILE" "$dest/docker.env"
  fi

  cat >"$dest/MANIFEST.txt" <<EOF
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
upload_location=$upload
hostname=$(hostname)
git_head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
EOF
  touch "$dest/.immich-backup-complete"

  prune_backups
  info "backup complete: $dest"

  if [[ "$was_running" == true ]] && ! stack_running; then
    info "restarting stack after backup"
    compose start
  fi
}

cmd_update() {
  local do_sync="$UPDATE_SYNC_ON_UPDATE"
  local do_backup="if-due"
  local rebase=false
  local check_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sync) do_sync=true ;;
      --no-sync) do_sync=false ;;
      --backup) do_backup=force ;;
      --no-backup) do_backup=skip ;;
      --rebase) rebase=true ;;
      --check) check_only=true ;;
      *) die "unknown update option: $1" ;;
    esac
    shift
  done

  ensure_env_file

  local host latest
  host="$(host_immich_version || true)"
  [[ -n "$host" ]] || die "could not determine host Immich version (API down and IMMICH_VERSION unset?)"
  latest="$(latest_immich_version)"

  local cmp_ec=0
  version_cmp "$host" "$latest" || cmp_ec=$?
  local status
  case "$cmp_ec" in
    0) status="up to date" ;;
    1) status="update available" ;;
    *) die "cannot compare versions host=$host latest=$latest" ;;
  esac
  print_version_comparison "$host" "$latest" "$status"

  if [[ "$cmp_ec" -eq 0 ]]; then
    info "nothing to do"
    return 0
  fi

  if [[ "$check_only" == true ]]; then
    info "check only — not applying update"
    return 0
  fi

  require_docker

  case "$do_backup" in
    force) do_backup ;;
    if-due) do_backup --if-due ;;
    skip) info "skipping backup (--no-backup)" ;;
  esac

  if [[ "$do_sync" == true || "$do_sync" == "true" ]]; then
    [[ -x "$SYNC_SCRIPT" ]] || die "missing $SYNC_SCRIPT"
    info "syncing from Immich upstream"
    if [[ "$rebase" == true ]]; then
      "$SYNC_SCRIPT" sync --rebase
    else
      "$SYNC_SCRIPT" sync
    fi
  else
    info "skipping git sync"
  fi

  info "setting IMMICH_VERSION=$latest"
  set_immich_version "$latest"

  info "pulling images"
  compose pull

  build_plugins
  info "rebuilding and recreating containers (bind mounts / data kept)"
  # Intentionally no -v / --renew-anon-volumes: protect library + postgres data.
  if ! compose up -d --build --remove-orphans --force-recreate; then
    die "recreate failed after pinning $latest — see backups under $BACKUP_DIR"
  fi
  start_lan_proxy
  verify_phone_access || true

  local final
  final="$(host_immich_version || true)"
  info "update complete — host now: ${final:-unknown} (target $latest)"
  compose ps
  info "API / web: http://127.0.0.1:2283"
}

cmd_schedule_hint() {
  local script="$ROOT/scripts/immich-app.sh"
  cat <<EOF
# Cron (weekly Sunday 03:15) — uses BACKUP_INTERVAL_DAYS via --if-due
15 3 * * 0 $script backup --if-due >>$BACKUP_DIR/backup.log 2>&1

# Cron (daily check; only backs up when due)
15 3 * * * $script backup --if-due >>$BACKUP_DIR/backup.log 2>&1

# macOS launchd (save as ~/Library/LaunchAgents/com.immich.backup.plist)
# ProgramArguments: $script
#               backup
#               --if-due
# StartCalendarInterval: Weekday=0 Hour=3 Minute=15

Config file: $CONFIG_FILE
BACKUP_DIR=$BACKUP_DIR
BACKUP_INTERVAL_DAYS=$BACKUP_INTERVAL_DAYS
EOF
}

main() {
  load_config
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  shift || true

  case "$cmd" in
    -h|--help|help) usage ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    down) cmd_down ;;
    status) cmd_status ;;
    backup) do_backup "$@" ;;
    update) cmd_update "$@" ;;
    schedule-hint) cmd_schedule_hint ;;
    *) die "unknown command: $cmd (try help)" ;;
  esac
}

if [[ "${IMMICH_APP_SOURCED:-}" == 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
