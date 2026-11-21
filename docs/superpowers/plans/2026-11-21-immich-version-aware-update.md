# Immich version-aware update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/immich-app.sh update` print host vs latest Immich release and auto-upgrade the `IMMICH_VERSION` pin + images when newer, with no prompt.

**Architecture:** Add small bash helpers in `immich-app.sh` (host version, GitHub latest, semver compare, pin write). `cmd_update` prints comparison first; exits early if current; otherwise backup → optional git sync → bump pin → `compose pull` → recreate. `--check` is compare-only.

**Tech Stack:** Bash, `curl`, GitHub Releases API, existing `docker compose` helpers in `scripts/immich-app.sh`.

**Spec:** `docs/superpowers/specs/2026-11-21-immich-version-aware-update-design.md`

## Global Constraints

- No interactive prompts on `update`.
- Stable releases only (`/releases/latest`).
- Never `docker compose down -v` or delete data paths.
- Fail closed if latest version cannot be resolved (do not change pin/containers).
- Git sync is independent; default `UPDATE_SYNC_ON_UPDATE=false`.
- Keep changes inside `scripts/immich-app.sh` (+ tiny self-check + doc/example tweaks); no new dependencies.

## File map

| File | Responsibility |
|------|----------------|
| `scripts/immich-app.sh` | Version helpers, `cmd_update` / usage / default sync |
| `scripts/test-immich-app-version.sh` | Runnable asserts for normalize/compare helpers |
| `scripts/immich-app.env.example` | Default `UPDATE_SYNC_ON_UPDATE=false` + short note |
| `docs/superpowers/specs/2026-08-16-immich-app-lifecycle-design.md` | One-line `update` row |

---

### Task 1: Version helpers + self-check

**Files:**
- Modify: `scripts/immich-app.sh` (add helpers after `env_get`, before `upload_location`)
- Create: `scripts/test-immich-app-version.sh`

**Interfaces:**
- Produces:
  - `normalize_version <raw>` → stdout `vMAJOR.MINOR.PATCH` or empty
  - `version_cmp <a> <b>` → exit 0 if a≥b, 1 if a<b, 2 if unparseable
  - `host_immich_version` → stdout normalized tag or empty
  - `latest_immich_version` → stdout tag or die
  - `print_version_comparison <host> <latest>` → prints one comparison line; echoes status word `up-to-date` or `update-available` on stdout last? Prefer: print human lines to stderr/stdout via `info`, return status via `version_cmp`. Keep it simple: `print_version_comparison` only prints; caller uses `version_cmp`.

- [ ] **Step 1: Write the failing self-check**

Create `scripts/test-immich-app-version.sh`:

```bash
#!/usr/bin/env bash
# Runnable check for immich-app.sh version helpers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=immich-app.sh
# Source only helpers by extracting — instead, define a tiny sourceable mode.
# Prefer: source a fragment. For this repo, source the script functions by
# setting a guard. Task 1 Step 3 will add:
#   if [[ "${IMMICH_APP_SOURCED:-}" == 1 ]]; then return 0; fi
# at the bottom before main, and skip main when sourced.
IMMICH_APP_SOURCED=1
# shellcheck disable=SC1091
source "$ROOT/scripts/immich-app.sh"

assert_eq() {
  local got="$1" want="$2" label="$3"
  [[ "$got" == "$want" ]] || { echo "FAIL $label: got='$got' want='$want'" >&2; exit 1; }
}

assert_eq "$(normalize_version '3.4.2')" 'v3.4.2' 'normalize plain'
assert_eq "$(normalize_version 'v3.4.2')" 'v3.4.2' 'normalize v-prefix'
assert_eq "$(normalize_version '{"major":3,"minor":4,"patch":2}')" 'v3.4.2' 'normalize json'

normalize_version 'nope' >/dev/null && { echo 'FAIL expected empty for nope'; exit 1; } || true
[[ -z "$(normalize_version 'nope' || true)" ]] || { echo 'FAIL nope'; exit 1; }

version_cmp v3.4.2 v3.4.2
[[ $? -eq 0 ]] || { echo 'FAIL 3.4.2 >= 3.4.2'; exit 1; }
version_cmp v3.4.2 v3.4.1
[[ $? -eq 0 ]] || { echo 'FAIL 3.4.2 >= 3.4.1'; exit 1; }
version_cmp v3.4.1 v3.4.2
[[ $? -eq 1 ]] || { echo 'FAIL 3.4.1 < 3.4.2'; exit 1; }

echo 'OK scripts/test-immich-app-version.sh'
```

Note: `version_cmp` checks under `set -e` need `version_cmp ... || ec=$?` pattern — use:

```bash
ec=0; version_cmp v3.4.1 v3.4.2 || ec=$?
[[ "$ec" -eq 1 ]] || { echo 'FAIL 3.4.1 < 3.4.2'; exit 1; }
```

- [ ] **Step 2: Run self-check — expect fail (helpers missing)**

Run: `bash scripts/test-immich-app-version.sh`  
Expected: FAIL / `normalize_version: command not found` (or source errors until guard exists).

- [ ] **Step 3: Implement helpers + source guard in `scripts/immich-app.sh`**

1. Change default:

```bash
UPDATE_SYNC_ON_UPDATE="${UPDATE_SYNC_ON_UPDATE:-false}"
```

2. After `env_get`, add:

```bash
normalize_version() {
  local raw="${1:-}" major minor patch
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
  local host="$1" latest="$2"
  local status
  if version_cmp "$host" "$latest"; then
    status="up to date"
  else
    local ec=$?
    if [[ "$ec" -eq 2 ]]; then
      die "cannot compare versions host=$host latest=$latest"
    fi
    status="update available"
  fi
  info "host: ${host:-unknown}  latest: ${latest}  status: ${status}"
}

set_immich_version() {
  local tag="$1" file="$ROOT/$ENV_FILE"
  [[ -f "$file" ]] || die "missing $file"
  if grep -qE '^IMMICH_VERSION=' "$file"; then
    # portable in-place replace (macOS)
    local tmp
    tmp="$(mktemp)"
    sed "s/^IMMICH_VERSION=.*/IMMICH_VERSION=${tag}/" "$file" >"$tmp"
    mv "$tmp" "$file"
  else
    printf '\nIMMICH_VERSION=%s\n' "$tag" >>"$file"
  fi
}
```

3. Replace bottom of file so sourcing works:

```bash
if [[ "${IMMICH_APP_SOURCED:-}" == 1 ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
```

- [ ] **Step 4: Run self-check — expect pass**

Run: `bash scripts/test-immich-app-version.sh`  
Expected: `OK scripts/test-immich-app-version.sh`

- [ ] **Step 5: Commit**

```bash
git add scripts/immich-app.sh scripts/test-immich-app-version.sh
git commit -m "$(cat <<'EOF'
feat(scripts): add Immich version compare helpers

EOF
)"
```

---

### Task 2: Wire version-aware `cmd_update` + `--check`

**Files:**
- Modify: `scripts/immich-app.sh` (`usage`, `cmd_update`)

**Interfaces:**
- Consumes: `host_immich_version`, `latest_immich_version`, `print_version_comparison`, `version_cmp`, `set_immich_version`, existing `do_backup` / `compose` / `build_plugins` / LAN proxy helpers

- [ ] **Step 1: Update `usage` text**

Replace the Commands / Update options section with:

```bash
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
```

- [ ] **Step 2: Rewrite `cmd_update`**

```bash
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
  print_version_comparison "$host" "$latest"

  if version_cmp "$host" "$latest"; then
    info "nothing to do"
    return 0
  fi
  local ec=$?
  [[ "$ec" -ne 2 ]] || die "cannot compare versions"

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
```

**Important:** under `set -e`, do not call `version_cmp` then read `$?` after a true branch without capturing:

```bash
  local cmp_ec=0
  version_cmp "$host" "$latest" || cmp_ec=$?
  print_version_comparison already calls version_cmp — either:
  - make print_version_comparison echo status and not call version_cmp twice, or
  - after print, re-run with `cmp_ec=0; version_cmp ... || cmp_ec=$?`
```

Use this exact control flow after resolving versions:

```bash
  print_version_comparison "$host" "$latest"

  local cmp_ec=0
  version_cmp "$host" "$latest" || cmp_ec=$?
  if [[ "$cmp_ec" -eq 0 ]]; then
    info "nothing to do"
    return 0
  fi
  [[ "$cmp_ec" -eq 1 ]] || die "cannot compare versions"

  if [[ "$check_only" == true ]]; then
    info "check only — not applying update"
    return 0
  fi
```

And simplify `print_version_comparison` to not `die` on cmp 2 if caller handles it — keep die inside print for bad compare when printing status, OR compute status from `cmp_ec` only in `cmd_update` and make print dumb:

```bash
print_version_comparison() {
  local host="$1" latest="$2" status="$3"
  info "host: ${host:-unknown}  latest: ${latest}  status: ${status}"
}
```

Caller:

```bash
  local cmp_ec=0
  version_cmp "$host" "$latest" || cmp_ec=$?
  local status
  case "$cmp_ec" in
    0) status="up to date" ;;
    1) status="update available" ;;
    *) die "cannot compare versions host=$host latest=$latest" ;;
  esac
  print_version_comparison "$host" "$latest" "$status"
```

Use this simpler three-arg print in the implementation (update Task 1 helper accordingly if already committed — amend in this task).

- [ ] **Step 3: Manual verify `--check`**

Run: `./scripts/immich-app.sh update --check`  
Expected: line with `host: v3.4.2  latest: v3.4.2  status: up to date` (or whatever is current) and `nothing to do` / check-only message; no docker recreate; `IMMICH_VERSION` unchanged.

- [ ] **Step 4: Re-run self-check**

Run: `bash scripts/test-immich-app-version.sh`  
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/immich-app.sh
git commit -m "$(cat <<'EOF'
feat(scripts): version-aware Immich update with --check

EOF
)"
```

---

### Task 3: Docs + env example

**Files:**
- Modify: `scripts/immich-app.env.example`
- Modify: `docs/superpowers/specs/2026-08-16-immich-app-lifecycle-design.md`
- Modify: `scripts/immich-app.env` only if present and local (gitignored — update for consistency, do not commit)

- [ ] **Step 1: Update example env**

Set:

```bash
# On update: also merge Immich upstream into the current git branch (optional)
UPDATE_SYNC_ON_UPDATE=false
```

Add above it:

```bash
# update compares host vs GitHub latest and bumps IMMICH_VERSION in docker/.env when newer
```

- [ ] **Step 2: Update lifecycle design table row**

Change `update` row to:

```markdown
| `update` | compare host vs GitHub latest; if newer → backup → optional git sync → bump `IMMICH_VERSION` → pull/recreate (data kept); `--check` compare-only |
```

- [ ] **Step 3: Commit**

```bash
git add scripts/immich-app.env.example docs/superpowers/specs/2026-08-16-immich-app-lifecycle-design.md docs/superpowers/specs/2026-11-21-immich-version-aware-update-design.md docs/superpowers/plans/2026-11-21-immich-version-aware-update.md
git commit -m "$(cat <<'EOF'
docs: version-aware Immich update spec and plan

EOF
)"
```

---

## Spec coverage checklist

| Spec requirement | Task |
|------------------|------|
| Print host vs latest | Task 2 |
| Auto-upgrade when newer, no prompt | Task 2 |
| Host from API else pin | Task 1 `host_immich_version` |
| Latest from GitHub `/releases/latest` | Task 1 `latest_immich_version` |
| No-op when up to date | Task 2 |
| `--check` | Task 2 |
| Bump pin + pull + recreate | Task 2 |
| Backup flags unchanged | Task 2 |
| Git sync opt-in / default false | Task 1 default + Task 2 + Task 3 |
| Fail closed on GitHub failure | Task 1 `latest_immich_version` die |
| Recreate failure mentions backup dir | Task 2 |
| Never `-v` | Task 2 (existing compose flags) |
| Lifecycle doc + example env | Task 3 |
| Runnable check for compare logic | Task 1 |

## Self-review notes

- Prefer three-arg `print_version_comparison` to avoid `set -e` / `$?` pitfalls (called out in Task 2).
- `normalize_version` JSON path uses a regex over the API body — adequate for Immich’s compact JSON; no `jq` dependency.
- Do not commit `docker/.env` or `scripts/immich-app.env`.
