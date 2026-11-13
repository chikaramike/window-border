---
title: AGENTS.md - window-border
created: 2026-11-13
updated: 2026-11-13
tags: [agents, entrypoint]
---

# AGENTS.md - window-border (fork)

Mike's fork of `crazyathlete220-stack/window-border`, a small macOS menu-bar app (Objective-C, one source file `Sources/main.m`, built with `make`) that draws a colored outline around each window. This is a contrib repo: someone else owns the upstream project.

## Shared rules (read before changes)

Read `_meta/shared-rules.md` and `_meta/USER.md` before making changes. Resolve `_meta` from the actual checkout, in this order: `../../_meta/` (grouped Mac layout, where this repo sits at `Developer/contrib/window-border`), then `../_meta/` (flat VPS layout), then the `_meta` folder already open in the multi-root workspace. If none is reachable, ask for its location before changing files; do not clone or move repos to satisfy the reference. These are explicit read instructions, not automatic imports. This file's own boundaries and verification steps still apply.

## Remotes and branches

- `origin` = `chikaramike/window-border` (Mike's fork). `upstream` = `crazyathlete220-stack/window-border` (read-only for us).
- `main` tracks upstream. Keep it clean: no personal commits.
- `feature/*` branches (`active-window-thickness`, `default-color`, `glow`) are candidates for upstream pull requests. One change per branch, no personal files.
- `personal-build` is the branch Mike runs day to day; it combines the features. This `AGENTS.md` lives on `personal-build` only. Do not add it to `main` or to a `feature/*` branch, and do not include it in an upstream pull request.
- Never push to `upstream`. Do not open, update, or close upstream issues or pull requests without Mike's request. [ISSUE_DRAFT.md](./ISSUE_DRAFT.md) is a draft, not a filed issue.

## Orientation (read first)

- [README.md](./README.md) - what the app does, build, install, run.
- `Sources/` - app source. `Makefile` - build targets. `examples/`, `assets/` - docs material.

## Commands

- `make app` - build `WindowBorder.app` (needs Xcode Command Line Tools, macOS 13+).
- `make install` - build and copy to `/Applications`. Only on Mike's request: it replaces the installed app.

## Conventions

- Match upstream code style and commit style on `feature/*` branches so pull requests stay reviewable. Mike's `type(scope): subject` convention applies on `personal-build`.
- Build output (`WindowBorder.app/`, `/window-border`) is ignored; never commit it.

## Verification

- After source changes run `make app` on the Mac and report the real result. The build cannot run on the VPS or in a Linux sandbox; say so if it was not run.

## Sync

- Mac only. See [the sync checklist](../../_meta/docs/machine/sync-checklist.md).
