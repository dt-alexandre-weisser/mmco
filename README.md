# mmco

Check out the GitHub branch you are looking at, in your local clone, from a button in Chrome.

Three pieces, one flow:

| Piece | Path | Role |
| --- | --- | --- |
| CLI | `bin/mmco` | Does everything: fetch, cleanup, checkout, install, open VS Code. Usable from a terminal on its own. |
| macOS app | `app/` | Faceless `mmco://` URL handler. Forwards `checkout` links to the CLI, hosts the Settings window. |
| Chrome extension | `extension/` | Injects **Checkout locally** on GitHub PR and branch pages; popup with Go + Settings. |

## Install

Requirements: macOS 14+, Command Line Tools (`xcode-select --install`), `jq`, `gh` logged in (`gh auth login`), VS Code with the `code` command.

```sh
git clone git@github.com:dt-alexandre-weisser/mmco.git ~/tools/mmco
cd ~/tools/mmco
./install.sh              # builds ~/Applications/mmco.app, links bin/mmco into ~/tools/bin (or /usr/local/bin)
```

Then load the extension once: `chrome://extensions` → Developer mode → **Load unpacked** → pick `~/tools/mmco/extension`.
On the first click Chrome asks "Open mmco?": tick **Always allow** and it never asks again.

Re-run `./install.sh` after pulling changes.

## Use

- On a GitHub PR: click **Checkout locally** next to the head branch.
- On `/branches`: each row has a small **mmco** button.
- Anywhere on GitHub: the toolbar popup shows the detected repo and branch, lets you type another branch, and holds the **Settings…** link.
- Terminal: `mmco DiliTrust/module-mm feat/MM-1234`, `mmco DiliTrust/module-mm` (default branch), `mmco --path ~/dev/foo some-branch`.

The first time a repo is seen, a folder picker asks where its clone lives. The answer is saved as a mapping row.

## What a run does

1. Resolve the mapping row for `owner/repo`.
2. Uncommitted **tracked** changes in the folder: dialog **Overwrite / Abort**. Overwrite is `git reset --hard`; untracked files are kept. Abort stops before anything is fetched.
3. `git fetch --all --prune`.
4. Run the row's **pre-checkout** block (default below).
5. Check out the branch, **always hard-reset to `origin/<branch>`**. Unknown branch, or none given: detached on `origin/<default>` (`develop` for module-mm, `main` for Design_System). Branch already checked out in another worktree: warning dialog naming it, then `--ignore-other-worktrees`.
6. Run the row's **post-checkout** block (default: install for the detected package manager).
7. Open VS Code on the folder and post a notification with the result and any warnings.

Everything is logged to `~/Library/Logs/mmco.log`.

## Settings

`mmco --settings` (or the popup link) opens the mapping table. One row per repo:

| Field | Meaning |
| --- | --- |
| Repository | `owner/repo`, as in the GitHub URL, case-insensitive |
| Local folder | the clone to operate on |
| Pre-checkout | shell run after the fetch, before the switch. Non-zero exit aborts the run. |
| Post-checkout | shell run after the switch, before VS Code opens. Non-zero exit is reported, VS Code still opens. |

Both blocks are full shell (zsh), run inside the folder with `MMCO_REPO`, `MMCO_PATH`, `MMCO_BRANCH`, `MMCO_DEFAULT_BRANCH` set. Each has a **Reset to default** button. The config is plain JSON at `~/.config/mmco/config.json` (`mmco --config` opens it).

### Default pre-checkout block

Deletes local branches whose upstream is gone (remote branch deleted) and local branches whose PR GitHub reports as merged. The second rule exists because rebase- and squash-merges rewrite SHAs, so `git branch --merged` sees nothing. Never deletes the branch being checked out nor the default branch. Print it with `mmco --default-pre`.

### Default post-checkout block

`pnpm install --config.confirmModulesPurge=false` for a `pnpm-lock.yaml`, `yarn install` for a `yarn.lock`, `npm install` for a `package-lock.json`, empty otherwise. Print it with `mmco --default-post <folder>`.

## Known limits

- PRs from a fork: the branch lives on the fork, not on `origin`; the run lands on the default branch with a warning.
- The app is built for the machine's CPU architecture. `install.sh` rebuilds it locally, so nothing is signed or notarised.
- Chrome only. The extension is MV3 and would load in other Chromium browsers, untested.

## Layout

```
bin/mmco                  the CLI
app/Sources/*.swift       AppKit shell + SwiftUI settings
app/Info.plist            LSUIElement, mmco:// scheme
app/build.sh              swiftc build, --install copies to ~/Applications
extension/                manifest.json, content.js, popup.*, icons/ (gen-icons.py regenerates them)
install.sh                one-shot install
```
