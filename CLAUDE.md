# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Fork Notice

This is a **personal fork** of [openclaw/openclaw](https://github.com/openclaw/openclaw).

- **origin**: `https://github.com/audichuang/openclaw.git` (this fork)
- **upstream**: `https://github.com/openclaw/openclaw.git` (official)

### Local Fix: Extension Relay targetId Matching

Branch `fix/extension-relay-targetid` contains a fix in `src/browser/pw-session.ts` (`findPageByTargetId` function) that prioritizes `/json/list` endpoint over Playwright CDP for tab matching. This fixes `browser snapshot` failing with "tab not found" when using Chrome Extension Relay (`profile="chrome"`).

**Before making any updates or syncing with upstream, read `FORK_MAINTENANCE.md` for the update workflow.**

## Build & Development Commands

| Task | Command |
|---|---|
| Install deps | `pnpm install` |
| Build | `pnpm build` |
| Type-check | `pnpm tsgo` |
| Lint + format check | `pnpm check` |
| Lint fix | `pnpm lint:fix` |
| Format fix | `pnpm format` |
| Run dev CLI | `pnpm openclaw ...` or `pnpm dev` |
| Run tests (parallel) | `pnpm test` |
| Run tests (fast) | `pnpm test:fast` |
| Run single test | `vitest run path/to/file.test.ts` |
| Run e2e tests | `pnpm test:e2e` |
| Run live tests | `OPENCLAW_LIVE_TEST=1 pnpm test:live` |
| Coverage | `pnpm test:coverage` |

After building from source, use `npm link` to make the global `openclaw` command point to this repo, then `openclaw gateway restart` to apply.

## Architecture Overview

OpenClaw is a multi-channel AI gateway that routes messages between messaging platforms and AI agents.

### Core Modules (`src/`)

- **`gateway/`** — WebSocket control plane server (central hub, `ws://127.0.0.1:18789`)
- **`cli/`** — Commander-based CLI wiring; dependency injection via `createDefaultDeps` in `src/cli/deps.ts`
- **`commands/`** — CLI command implementations (agent, gateway, browser, config, etc.)
- **`agents/`** — AI agent runtime using Pi integration (`@mariozechner/pi-*`)
- **`browser/`** — Browser automation via Playwright/CDP with Extension Relay support; profiles and snapshots
- **`channels/`** — Core messaging channel abstractions
- **`routing/`** — Message routing between channels and agents
- **`config/`** — Configuration loading (`~/.openclaw/openclaw.json`) and session management
- **`media/`** — Media processing pipeline (images, audio, video)
- **`canvas-host/`** — A2UI Canvas rendering for agent-driven visual workspace
- **`terminal/`** — Terminal output helpers: `table.ts` (tables), `theme.ts` (colors), `palette.ts` (CLI palette)
- **`infra/`** — Infrastructure utilities (env, ports, time formatting via `format-time`)

### Extensions & Plugins

- **`extensions/`** — Channel plugins as workspace packages (Telegram, Discord, Slack, WhatsApp, Matrix, Teams, Signal, LINE, Feishu, Zalo, etc.)
- **`skills/`** — Bundled agent skills (1password, github, etc.)
- **`packages/`** — Workspace packages (clawdbot, moltbot)

### Apps

- **`apps/macos/`** — macOS menu bar app (Swift)
- **`apps/ios/`**, **`apps/android/`** — Mobile apps

### UI

- **`ui/`** — Control UI (Lit + Vite web interface)

## Key Conventions

- **TypeScript ESM** with strict typing; avoid `any`; use `.js` extensions for cross-package imports
- **No redundant re-exports**: import directly from original source, never create wrapper files
- **Centralized utilities**: time formatting in `src/infra/format-time`, tables in `src/terminal/table.ts`, progress in `src/cli/progress.ts`
- **Tests colocated**: `*.test.ts` next to source, `*.e2e.test.ts` for e2e, `*.live.test.ts` for live
- **Coverage thresholds**: 70% lines/functions/statements, 55% branches
- **Commits**: use `scripts/committer "<msg>" <file...>` to keep staging scoped
- **Files**: aim for under ~700 LOC; split when it improves clarity
- **Lint/format**: Oxlint + Oxfmt; run `pnpm check` before commits
- Plugin deps go in the extension's own `package.json`, not root
- Patched dependencies (`pnpm.patchedDependencies`) must use exact versions (no `^`/`~`)

## Full Upstream Guidelines

For the complete upstream contributor guidelines (release workflow, GHSA patches, multi-agent safety, docs i18n, macOS packaging, etc.), see `AGENTS.md`.
