# Immich version-aware update — design
# Date: 2026-11-21 | Status: Approved

Extends `docs/superpowers/specs/2026-08-16-immich-app-lifecycle-design.md`.

## Goal

When running `scripts/immich-app.sh update`, show host vs latest Immich release, then automatically upgrade the running stack if a newer stable release exists. No interactive prompt.

## Context

This install uses release compose (`docker/docker-compose.yml`) with images pinned by `IMMICH_VERSION` in `docker/.env`. Bumping that pin + pull + recreate is what upgrades the running app. Git sync upgrades the repo only and stays optional.

## Version sources

| Role | Source |
|------|--------|
| Host | Prefer running API `GET http://127.0.0.1:2283/api/server/version` → `v{major}.{minor}.{patch}`; else `IMMICH_VERSION` from `docker/.env` |
| Latest | GitHub `GET /repos/immich-app/immich/releases/latest` → `tag_name` (stable only; no prereleases) |

Compare as semver (`v` optional). Host ≥ latest → up to date. Host < latest → update available. Unparseable / unreachable latest → fail closed (no partial upgrade).

## `update` flow

1. Resolve host and latest; print comparison, e.g.  
   `host: v3.4.2` · `latest: v3.4.3` · `status: update available`  
   or `status: up to date`.
2. If up to date → exit 0 (skip backup, pull, recreate).
3. If update available:
   - Backup per existing flags (`--backup` / `--no-backup` / default if-due).
   - Set `IMMICH_VERSION=<latest tag>` in `docker/.env` (preserve other keys).
   - `compose pull`
   - `compose up -d --build --remove-orphans --force-recreate` (never `-v`).
   - Restart LAN proxy; verify phone access as today.
   - Print final host version from API when ready.
4. Git sync: independent of the image upgrade. Change default `UPDATE_SYNC_ON_UPDATE` to `false` so a dirty tree cannot block pin/pull/recreate. `--sync` / config `true` still runs `sync-upstream.sh` after backup and before pin bump when requested.

## Flags

| Flag | Behavior |
|------|----------|
| `--check` | Compare only; no backup, pin write, pull, or recreate |
| `--backup` / `--no-backup` | Unchanged |
| `--sync` / `--no-sync` | Unchanged (git); independent of image upgrade |
| `--rebase` | Unchanged (with `--sync`) |

## Errors

- GitHub (or version resolution) fails → non-zero exit; do not change pin or containers.
- Pull/recreate fails after pin write → leave pin as written; message points at last backup path.

## Non-goals

- Interactive confirmations
- Prerelease / RC tracking
- Changing postgres/redis image digests beyond what compose already pins
- Making git sync the primary upgrade mechanism

## Implementation touchpoints

- `scripts/immich-app.sh` — helpers + `cmd_update` (+ usage)
- `docs/superpowers/specs/2026-08-16-immich-app-lifecycle-design.md` — one-line update of the `update` row
- Optional: `scripts/immich-app.env.example` note that image upgrades follow GitHub latest via `IMMICH_VERSION`
