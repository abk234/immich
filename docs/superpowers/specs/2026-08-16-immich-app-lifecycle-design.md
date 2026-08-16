# Immich local app lifecycle — design
# Date: 2026-08-16 | Status: Approved

## Goal

Manage start/stop/update of the local Immich stack and configurable backups so upgrades never wipe library/DB data.

## Stack

- Compose: `docker/docker-compose.dev.yml` (project `immich-dev`)
- Data: `${UPLOAD_LOCATION}/photos` and `${UPLOAD_LOCATION}/postgres` (from `docker/.env`)
- Never run `docker compose down -v` or delete data paths

## Commands

| Command | Behavior |
|---------|----------|
| `start` | `compose up -d --remove-orphans` |
| `stop` | `compose stop` (containers stop; data kept) |
| `down` | `compose down --remove-orphans` (no `-v`) |
| `status` | containers, data paths, last backup |
| `backup` | snapshot data into `BACKUP_DIR/<timestamp>/` |
| `backup --if-due` | backup only if older than `BACKUP_INTERVAL_DAYS` |
| `update` | backup (due/forced) → optional git sync → rebuild/recreate without wiping data |
| `schedule-hint` | print cron/launchd examples |

## Config (`scripts/immich-app.env`)

See `scripts/immich-app.env.example`.
