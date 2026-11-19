# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:46cd31e7 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## Build & Test

There is no build step: the shell loads the QML and helpers straight from the
plugin folder.

```bash
scripts/check.sh   # manifest validation, defaults vs schema, syntax of every file
./hw-probe | jq    # the sensors the probe finds on this machine
```

The README's Development section has the loop for trying a change in your own
bar.

## Architecture Overview

The shell loads these files straight from the plugin folder; there is no build
step.

- `Widget.qml`: the bar widget, the manifest's `barWidget` entry point.
- `SystemPanel.qml`: the popup panel a left click opens.
- `Dial.qml` and `Gauge.qml`: drawing, the panel's dials and the bar's capsule
  gauges.
- `Service.qml`: sampling and its timers. It reads `/proc` and `/sys` directly
  and runs the two helpers below.
- `GuardedProcess.qml`: runs one helper process with a timeout and an output
  cap.
- `Model.js`: parsing and formatting, as pure functions.
- `hw-probe`: bash; finds this machine's sensor files once and prints them as
  JSON.
- `proc_top.py`: the panel's top-processes list, run only while the panel is
  open.

## Conventions & Patterns

- Every tracked file ships to users: `omarchy plugin add` installs with
  `git clone` and `omarchy plugin update` fast-forwards.
- A user-visible change gets an entry under `## Unreleased` in `CHANGELOG.md`;
  `scripts/release.sh` turns those notes into the version entry.
- `scripts/check.sh` must pass before pushing. Among other checks, it fails
  when a key's value in the manifest's `barWidget.defaults` differs from its
  schema `defaultValue`, or only one of the two sets it.
- Setting keys and values already in users' `shell.json` must keep working:
  a retired value is still read, as `percentPad: "trail"` and its older name
  `"space"` are.
