# GitHub Dashboard

A small native app for macOS and iOS that answers four questions:

- Which of my pull requests are open?
- Which pull requests are waiting for my review?
- What happened in them since I last looked?
- How many lines did I write this week?

## Run it

You need Xcode 16 or newer.

```bash
./run_macos.sh            # build and open
./run_macos.sh --install  # also copy to /Applications
./run_ios.sh              # build and open in the iOS Simulator
```

## Sign in

The app needs a GitHub token. It looks for one in this order:

1. **Keychain** — paste a token in the app's Settings. Works on macOS and iOS.
2. **`GH_TOKEN`** environment variable.
3. **GitHub CLI** (macOS only) — if you ran `gh auth login`, there is nothing to do.

A [fine-grained token](https://github.com/settings/personal-access-tokens) with read-only **Pull requests** and
**Contents** access is enough. The token is never written to the app bundle, to preferences or to logs.

## Configure

Everything is optional. Copy `.env.example` to `.env` and edit:

| Key | What it does |
|---|---|
| `GITHUB_ORGS` | Show only these organizations or users, e.g. `acme, octocat`. Empty = all repositories. |
| `IGNORED_LOGINS` | Hide activity from these logins, e.g. a CI account. Bots are always hidden. |
| `BUNDLE_ID`, `DEVELOPMENT_TEAM` | App identity and signing, for a real device. |
| `GH_TOKEN` | iOS Simulator only: token handed to the app at launch. |
| `IOS_SIMULATOR` | Simulator name for `run_ios.sh`. |

`.env` is git-ignored. It only sets the defaults: in Settings you can tick your personal account and each
organization, or add another one by name.

## How it counts

- **New** means activity by someone else since you last opened that pull request. Before the first open,
  everything since Monday is new.
- **Lines this week** are your non-merge commits, since Monday, in your pull requests. Direct pushes without a
  pull request are not counted.

## Develop

```bash
swift test --package-path Core   # logic tests, no network
xcodegen                         # regenerate the Xcode project after editing project.yml
```

| Path | What lives there |
|---|---|
| `Core/` | Swift package: GitHub API, tokens, statistics, app state. No UI. |
| `App/` | SwiftUI views for macOS and iOS. |
| `project.yml` | Source of the Xcode project. |
