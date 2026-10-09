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

Each build records the commit it came from; Settings shows it under **Built from** (`-dirty` means it had
uncommitted changes). `--install` refuses to run with uncommitted changes, so the copy in `/Applications` always
matches a commit. Both scripts fail if the app does not come up.

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
| `IOS_SIMULATOR` | Simulator name for `run_ios.sh`. |

There is no token in `.env`: `run_ios.sh` hands the simulator `gh auth token`, or `GH_TOKEN` if you export it in
your shell. `.env` is git-ignored. It only sets the defaults: in Settings you can tick your personal account and each
organization, or add another one by name.

## Claude reviews (macOS)

With [Claude Code](https://claude.com/claude-code) installed and signed in, the app can review pull requests
for you. Open **Claude reviews**, press **Review**, and each finding shows:

- a severity (high, medium, low) and a category: regression, security, reliability, modularity, structure, smell
- a link to the exact line on github.com
- what is wrong, a failing example and a fix, in plain words, and also as pictures: the steps that lead to the
  failure, a now-and-after table, three rough scales (harm, how often, cost to fix), the code with the
  suggested change, and a map of where the finding sits among the changed files
- a comment shown as GitHub will render it, which you can edit first: **Publish** puts it on that line of the pull request under your account, after you
  confirm; **Copy** if you would rather paste it yourself

The pane lists review requests and also the open pull requests you have already reviewed, because GitHub
withdraws a request as soon as you comment. It has three columns: pull requests, the findings of the selected one, and one finding in full; the
arrow keys move through them. Select several pull requests (shift or command click) and right-click to review
them all, mark them done or open them. **Done** hides a pull request until there is new activity in it.

Nothing is posted to GitHub unless you press Publish. Publishing needs a token that may write to the
repository; a read-only token is enough for everything else. In Settings you can also:

- **Review new requests automatically** - requests that arrive after you switch it on, and new commits in
  pull requests already reviewed. A daily spending limit keeps a burst of requests from running away.
- **Write a lesson for each review** - a short HTML lesson in `~/learn/<repo>/pr-<number>/` with a diagram of
  the change, where it sits in the code and what was found. Needs the `teach` skill in Claude Code.

**Claude usage** lists every run of the last twelve months with its tokens and cost. When a review fails, or
automatic reviews wait because the daily limit is reached, the menu bar icon turns into a warning and its menu
says which.

The review follows one fixed form, defined by the [pr-review skill](skills/pr-review/SKILL.md). To use the
same skill in your own Claude Code sessions (`/pr-review owner/repo#123`):

```bash
./scripts/install_skill.sh
```

Pull request text is untrusted, so the review runs with no tools at all: Claude receives the diff and returns
the form, and the app builds every link itself.

## Restart failed Jenkins jobs

Flaky CI does not have to mean pressing Restart by hand. In **Settings → Auto-restart failed CI** enter the Jenkins
address (e.g. `https://ci.example.com`), your Jenkins user and an API token (Jenkins → your name → Security → API
Token; it is kept in the Keychain). Then press ↻ next to any pull request in **My PRs**, or switch on **All my pull
requests**.

On each refresh the app looks at the head commit's checks. A check that failed and links to that Jenkins is started
again through `buildWithParameters` (or `build` for a job without parameters):

- only your own pull requests, and only checks on the Jenkins you entered, so the token never goes anywhere else
- at most 2 restarts per check per commit (1 to 5 in Settings); a new commit starts the count again
- one restart per failed run: while GitHub still shows that run, the restart is on its way
- **Only these checks** narrows it down by name or prefix, e.g. `jenkins/prs/linux`

## Notifications

While the app runs it checks your GitHub notifications every minute and shows a system notification for:

- a comment or review on your pull request
- a reply in a conversation you commented in
- a mention of you or your team
- a review request or an assignment

Each one can be switched off in Settings → **Notifications**. Your own comments and bots are skipped, nothing from
before the first start pops up, and clicking a notification opens the pull request. GitHub does not let
fine-grained tokens read notifications: sign in with the GitHub CLI, or use a classic token with the
`notifications` scope.

## How it counts

- **New** means activity by someone else since you last opened that pull request. Before the first open,
  everything since Monday is new.
- **Lines this week** are your non-merge commits, since Monday, in your pull requests. Direct pushes without a
  pull request are not counted.

## Develop

```bash
swift test --package-path Core   # logic tests, no network
LIVE_CLAUDE=1 swift test --package-path Core --filter Live   # one real Claude run, spends tokens
xcodegen                         # regenerate the Xcode project after editing project.yml
```

| Path | What lives there |
|---|---|
| `Core/` | Swift package: GitHub API, tokens, statistics, reviews, app state. No UI. |
| `skills/pr-review/` | The review form: instructions, JSON schema, example, lesson brief. |
| `App/` | SwiftUI views for macOS and iOS. |
| `project.yml` | Source of the Xcode project. |
