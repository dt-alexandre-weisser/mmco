# mmco

Check out the GitHub branch you are looking at, in your local clone, from a button in Chrome.

Three pieces, one flow:

| Piece | Path | Role |
| --- | --- | --- |
| CLI | `bin/mmco` | Does everything: fetch, cleanup, checkout, open the folder, run the post-checkout block. Usable from a terminal on its own. |
| macOS app | `app/` | Faceless `mmco://` URL handler and Chrome native-messaging host. Starts CLI runs, reports their state to the extension, hosts the Settings window. |
| Chrome extension | `extension/` | Injects **Checkout locally** on GitHub PR and branch pages, with a spinner while the run goes on; popup with the run state, Go, Stop and Settings. |

## Install

Requirements: macOS 14+, Command Line Tools (`xcode-select --install`), `jq`, `gh` logged in (`gh auth login`), VS Code with the `code` command.

```sh
git clone git@github.com:dt-alexandre-weisser/mmco.git ~/tools/mmco
cd ~/tools/mmco
./install.sh              # builds ~/Applications/mmco.app, links bin/mmco, registers the native host
```

Then load the extension once: `chrome://extensions` → Developer mode → **Load unpacked** → pick `~/tools/mmco/extension`.

`install.sh` computes the extension id from that path and allows it in the native-host manifest. If the popup reports "host unreachable", the id differs: re-run `./install.sh --extension-id <id>` with the id the popup shows. Without the host the button still works through the `mmco://` URL (Chrome asks "Open mmco?" once, tick **Always allow**), but shows no progress.

Re-run `./install.sh` after pulling changes, then reload the extension in `chrome://extensions`.

## Use

- On a GitHub PR: click **Checkout locally** next to the head branch. It spins through the checkout, reads **Post-checkout…** while the block runs, then **Checked out** or **Failed** (hover for the reason).
- On `/branches`: each row has a small **mmco** button with the same states.
- Anywhere on GitHub: the toolbar popup shows the detected repo and branch, the current run (phase, last log lines), lets you type another branch, and holds **Stop**, **Settings…**, **Config file** and **Log**.
- Terminal: `mmco DiliTrust/module-mm feat/MM-1234`, `mmco DiliTrust/module-mm` (default branch), `mmco --path ~/dev/foo some-branch`. `--in vscode` / `--in terminal` before the other arguments overrides the row's choice. `mmco --state DiliTrust/module-mm` prints the last run's state.

The first time a repo is seen, a folder picker asks where its clone lives. The answer is saved as a mapping row.

## What a run does

1. Resolve the mapping row for `owner/repo`.
2. Uncommitted **tracked** changes in the folder: dialog **Overwrite / Abort**. Overwrite is `git reset --hard`; untracked files are kept. Abort stops before anything is fetched.
3. `git fetch --all --prune`.
4. Run the row's **pre-checkout** block (default below).
5. Check out the branch, **always hard-reset to `origin/<branch>`**. Unknown branch, or none given: detached on `origin/<default>` (`develop` for module-mm, `main` for Design_System). Branch already checked out in another worktree: warning dialog naming it, then `--ignore-other-worktrees`.
6. Open the folder where the row says: **VS Code** (`code <folder>`, default) or a **Terminal.app** window in the folder. `MMCO_NO_OPEN=1` skips this.
7. Run the row's **post-checkout** block (default: install for the detected package manager) inside mmco. A copy with the `MMCO_*` variables baked in is written to `<folder>/.git/mmco/post-checkout.sh` to rerun by hand. A block that never exits (a dev server) keeps the run alive: the extension shows **Post-checkout…** and its popup can **Stop** it. Checking out another branch of the same repo stops the previous run first.
8. Post a notification with the result and any warnings.

Everything is logged to `~/Library/Logs/mmco.log` (`mmco --log`).

### Run state

Each run writes `~/Library/Application Support/mmco/runs/<owner__repo>/state.json` (repo, branch, phase, status `running|done|failed|stopped`, pid, warnings) and `run.log`. The CLI rewrites `state.json` at every phase. The native host polls both, adds whether the pid is still alive, and streams the result to the extension. A run whose process died while the file still says `running` is reported as failed.

## Settings

`mmco --settings` (or the popup link) opens the mapping table. One row per repo:

| Field | Meaning |
| --- | --- |
| Repository | `owner/repo`, as in the GitHub URL, case-insensitive |
| Local folder | the clone to operate on |
| Pre-checkout | shell run after the fetch, before the switch. Non-zero exit aborts the run. |
| Post-checkout | shell run after the switch, in mmco. Output in the log and the extension. |
| Open a Terminal window instead of VS Code | checkbox. Off: `code <folder>`. On: Terminal.app window in the folder. |

Both blocks are full shell (zsh), run inside the folder with `MMCO_REPO`, `MMCO_PATH`, `MMCO_BRANCH`, `MMCO_DEFAULT_BRANCH` set. Each has a **Reset to default** button. The config is plain JSON at `~/.config/mmco/config.json` (`mmco --config` opens it).

### Default pre-checkout block

Deletes local branches whose upstream is gone (remote branch deleted) and local branches whose PR GitHub reports as merged. The second rule exists because rebase- and squash-merges rewrite SHAs, so `git branch --merged` sees nothing. Never deletes the branch being checked out nor the default branch. Print it with `mmco --default-pre`.

### Default post-checkout block

`pnpm install --config.confirmModulesPurge=false` for a `pnpm-lock.yaml`, `yarn install` for a `yarn.lock`, `npm install` for a `package-lock.json`, empty otherwise. Print it with `mmco --default-post <folder>`.

## How the extension talks to the app

The extension's background worker opens a `chrome.runtime.connectNative("com.aweisser.mmco")` port. Chrome starts `mmco.app`'s binary with the extension origin as argument, which puts it in host mode (`NativeHost.swift`). The host spawns the CLI in its own session with its streams on `/dev/null`, because Chrome kills the host a couple of seconds after the port closes and the run must outlive it. State flows through the run folder, never through pipes. **Stop** is `SIGTERM` to the run's process group, `SIGKILL` five seconds later.

## Known limits

- PRs from a fork: the branch lives on the fork, not on `origin`; the run lands on the default branch with a warning.
- The app is built for the machine's CPU architecture. `install.sh` rebuilds it locally, so nothing is signed or notarised.
- Chrome only in practice. `install.sh` also writes the host manifest for other Chromium browsers it finds installed, untested.
- The native-host manifest allows the extension ids computed from the extension folder path. An extension loaded from another path has another id: `./install.sh --extension-id <id>`. Chrome's error for a mismatch is "Access to the specified native messaging host is forbidden".
- A post-checkout block that starts a dev server never exits, so the run stays `running` until stopped from the popup, or replaced by the next checkout of the same repo.

## Layout

```
bin/mmco                  the CLI
app/Sources/*.swift       AppKit shell, SwiftUI settings, NativeHost + RunLauncher (Chrome host)
app/Info.plist            LSUIElement, mmco:// scheme
app/build.sh              swiftc build, --install copies to ~/Applications
extension/                manifest.json, background.js, content.js, popup.*, icons/ (gen-icons.py regenerates them)
install.sh                one-shot install, writes the native-messaging host manifest
```
