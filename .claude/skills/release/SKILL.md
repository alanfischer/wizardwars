---
name: release
description: Ship Wizard Wars — runs ./release.sh, which builds every client, packages the server, uploads to the release server (from the gitignored release.env) and restarts it. Use when the user says /release, "ship it", "deploy", "push a release", or asks to get merged work in front of players.
---

# Release

Run `./release.sh` from the project root, passing through any arguments the user gave.

```bash
./release.sh
```

This takes many minutes — rebuilding any stale GDExtension, converting assets, exporting the
macOS, Windows and Linux clients plus the Linux server, then rsyncing ~600MB and restarting the
remote server. **Run it in the background and wait for it once.** Do not poll it with `sleep`.

## Arguments worth knowing

Pass these straight through when the user names them:

- `--serve` — build the clients, then host locally instead of uploading. The local equivalent of a
  plain release; add `--map <name>` to pick the map.
- `--map <name>` — the map the restarted server comes up on (default `ww_2fort`).
- `--no-restart` — upload but leave the running server alone.
- `--rebuild-ext` — force a GDExtension rebuild even when the sources look unchanged.
- `--all-maps` — convert and ship every BSP. By default only the maps in `maps/mapcycle.txt` are
  converted and uploaded, and any other map on the server is deleted.

## Before you start

- **It restarts the live server, dropping anyone currently playing.** If the user has been talking
  about players being on right now, say so in one line and let them decide — otherwise just run it.
- Releasing ships whatever is committed on `main`. Mention anything still uncommitted in the working
  tree rather than silently shipping without it.

## When it finishes

`release.sh` exits non-zero on any failure and the build guards are loud, so read the tail of the
output rather than assuming. Report:

- the version stamp it wrote (`<short sha>-<timestamp>`, echoed as `Version: …`),
- the zip sizes it packaged,
- whether the remote server actually restarted (it prints `Server started (PID …)`).

Players pick the new build up through the launcher, which re-downloads when the version stamp
changes.
