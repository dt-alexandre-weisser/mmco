# mmco

Check out the GitHub branch you are looking at, in your local clone, from a button in Chrome.

Three pieces, one flow:

| Piece | Path | Role |
| --- | --- | --- |
| CLI | `bin/mmco` | Does everything: fetch, cleanup, checkout, then hands the install to VS Code or Terminal. Usable from a terminal on its own. |
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
- Terminal: `mmco DiliTrust/module-mm feat/MM-1234`, `mmco DiliTrust/module-mm` (default branch), `mmco --path ~/dev/foo some-branch`. `--in vscode` / `--in terminal` before the other arguments overrides the row's choice.

The first time a repo is seen, a folder picker asks where its clone lives. The answer is saved as a mapping row.

## What a run does

1. Resolve the mapping row for `owner/repo`.
2. Uncommitted **tracked** changes in the folder: dialog **Overwrite / Abort**. Overwrite is `git reset --hard`; untracked files are kept. Abort stops before anything is fetched.
3. `git fetch --all --prune`.
4. Run the row's **pre-checkout** block (default below).
5. Check out the branch, **always hard-reset to `origin/<branch>`**. Unknown branch, or none given: detached on `origin/<default>` (`develop` for module-mm, `main` for Design_System). Branch already checked out in another worktree: warning dialog naming it, then `--ignore-other-worktrees`.
6. Write the row's **post-checkout** block (default: install for the detected package manager) to `<folder>/.git/mmco/post-checkout.sh`, with the `MMCO_*` variables baked in, and open it where the row says:
   - **VS Code** (default): `code` opens `<folder>/.git/mmco/<folder>.code-workspace`, a workspace on the folder whose `folderOpen` task runs the script in the integrated terminal. Output stays in the panel. The task is also the default build task, so ⇧⌘B reruns it, which is what you need when the workspace was already open (a `folderOpen` task only fires on open). An empty block opens the folder directly, without a workspace. Two VS Code gates apply, see the known limits below.
   - **Terminal**: a Terminal.app window opens in the folder and runs the script. The shell stays open afterwards.
7. Post a notification with the result and any warnings.

Everything is logged to `~/Library/Logs/mmco.log`.

## Settings

`mmco --settings` (or the popup link) opens the mapping table. One row per repo:

| Field | Meaning |
| --- | --- |
| Repository | `owner/repo`, as in the GitHub URL, case-insensitive |
| Local folder | the clone to operate on |
| Pre-checkout | shell run after the fetch, before the switch. Non-zero exit aborts the run. |
| Post-checkout | shell run after the switch, in the chosen terminal. Its exit code is printed there. |
| Run it in a Terminal window instead of VS Code | checkbox. Off: VS Code workspace + `folderOpen` task. On: Terminal.app window. |

Both blocks are full shell (zsh), run inside the folder with `MMCO_REPO`, `MMCO_PATH`, `MMCO_BRANCH`, `MMCO_DEFAULT_BRANCH` set. Each has a **Reset to default** button. The config is plain JSON at `~/.config/mmco/config.json` (`mmco --config` opens it).

### Default pre-checkout block

Deletes local branches whose upstream is gone (remote branch deleted) and local branches whose PR GitHub reports as merged. The second rule exists because rebase- and squash-merges rewrite SHAs, so `git branch --merged` sees nothing. Never deletes the branch being checked out nor the default branch. Print it with `mmco --default-pre`.

### Default post-checkout block

`pnpm install --config.confirmModulesPurge=false` for a `pnpm-lock.yaml`, `yarn install` for a `yarn.lock`, `npm install` for a `package-lock.json`, empty otherwise. Print it with `mmco --default-post <folder>`.

## Known limits

- PRs from a fork: the branch lives on the fork, not on `origin`; the run lands on the default branch with a warning.
- The app is built for the machine's CPU architecture. `install.sh` rebuilds it locally, so nothing is signed or notarised.
- Chrome only. The extension is MV3 and would load in other Chromium browsers, untested.
- VS Code runs a `folderOpen` task only in a **trusted** workspace. The workspace file sits inside the folder's `.git`, so a folder you already trust gives a trusted workspace. Otherwise VS Code opens in Restricted Mode and asks: trust it.
- VS Code ships `task.allowAutomaticTasks` **off**. The first time a trusted mmco workspace opens, a notification asks about the task: answer **Allow and Run**, which turns the setting on for good. Dismissing it without answering silences that workspace instead. Recover with the command `Tasks: Manage Automatic Tasks`, or set `"task.allowAutomaticTasks": "on"` in the user settings. Until the setting is on, mmco's notification says so.
- A `folderOpen` task runs only when the workspace opens. If the mmco workspace is already open in VS Code, the branch is switched but the post-checkout block is not rerun: press ⇧⌘B, or run the script printed in the log.
- The VS Code window is titled `<repo> (Workspace)` and keeps its own UI state, separate from a window opened on the bare folder.

## Layout

```
bin/mmco                  the CLI
app/Sources/*.swift       AppKit shell + SwiftUI settings
app/Info.plist            LSUIElement, mmco:// scheme
app/build.sh              swiftc build, --install copies to ~/Applications
extension/                manifest.json, content.js, popup.*, icons/ (gen-icons.py regenerates them)
install.sh                one-shot install
```
