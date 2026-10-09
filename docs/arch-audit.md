# Architecture audit log

One row per run of the `arch-audit` checklist: thirty yes/no checks, ten per axis, each scored out of 10.
Read as a desktop app: an "expensive route" is a Claude run, a "deployment" is the build in `/Applications`.

| Date | Commit | Security | Reliability | Modularity | Main risk |
|---|---|---|---|---|---|
| 2026-10-08 | c24613c | 7 | 6 | 8 | The fallback GitHub CLI token can write to repositories although the app only reads. |
| 2026-10-09 | cd52470 | 8 | 3 | 4 | Quitting the app during a Claude run loses the paid result and its usage record. |
| 2026-10-09 | cfb67d6 | 8 | 5 | 5 | The installed app does not know which commit it was built from, and nothing prunes `~/learn` or the usage log. |

## Still failing at cfb67d6

**Security**
- S2 - `GH_TOKEN` may sit in `.env` in plain text.
- S6 - the fallback GitHub CLI token has write scopes, and Publish now uses them.

**Reliability**
- R4 - the app is built from the working copy by `run_macos.sh`, not from a pinned commit.
- R6 - the run scripts do not check that the app came up.
- R7 - the build in `/Applications` carries no version or commit.
- R8 - a failed automatic review or an exhausted daily budget is only visible in the window.
- R9 - `usage.json` and the lesson folders grow without limit.

**Modularity**
- M3 - `ReviewWorkspace` has no interface or in-memory implementation; tests write to a temporary folder.
- M5 - `ClaudeEngine.swift` reads the process environment outside `AppConfig`.
- M7 - the app name is written in both `scripts/lib.sh` and `project.yml`; `project.yml` and the `.xcodeproj` are kept in step by hand.
- M8 - `ReviewTests.swift` uses `@testable import`.
- M10 - user-facing error texts live in the core package.

## What moved between the last two rows

- R1 - a run's output goes to a file and is journaled; results that finish after the app quit are adopted on the next launch, and queued requests survive a restart.
- R5 - `main` requires the `test` check, for administrators too.
- M1 - `ReviewCoordinator` was split into `ReviewLibrary`, `CommentPublishing`, `AutoReviewPolicy`, `DoneMarks` and `RunJournal`.
