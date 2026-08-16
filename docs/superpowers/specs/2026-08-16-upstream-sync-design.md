# Upstream sync script — design

**Date:** 2026-08-16  
**Status:** Approved

## Goal

Keep this personal fork current with [immich-app/immich](https://github.com/immich-app/immich) while preserving local work. Never push to the original Immich repository.

## Remotes

| Remote    | Role                                      |
|-----------|-------------------------------------------|
| `upstream` | Fetch-only from `immich-app/immich`       |
| `origin`   | Push/pull for this fork (`abk234/immich`) |

`upstream` push URL is disabled (`no_push`) so accidental pushes to Immich are impossible.

## Commands

| Command | Behavior |
|---------|----------|
| `status` | Fetch upstream; show commits behind/ahead vs `upstream/main` |
| `sync` | Fetch upstream; merge `upstream/main` into current branch |
| `sync --rebase` | Same, but rebase onto `upstream/main` |
| `push` | Push current branch to `origin` only |

## Safety

- Abort if working tree is dirty (unless `--force-dirty`)
- Never run `git push upstream`
- On merge/rebase conflict: stop with clear next steps
- Default branch to compare/sync against: `upstream/main`

## Out of scope

- Opening PRs to Immich
- Automated conflict resolution
- Syncing non-`main` upstream branches (can be added later via `--branch`)
