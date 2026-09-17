# Dotstate

Dotfiles management for [Omarchy](https://omarchy.org/) (Arch + Hyprland),
built around a bar-widget plugin: after one `omarchy plugin add` command,
first-time setup, syncing, and day-to-day checks all happen by clicking in
the panel — no shell commands to learn, no README required. It's also
built to fail safely: `install.sh` and `adopt.sh` both refuse to silently
overwrite a config another repo already manages, the two mistakes that have
previously broken a real desktop (see [The bar
widget](#the-bar-widget) and [Why install.sh refuses to relink some
paths](#why-installsh-refuses-to-relink-some-paths) below).

Dotstate itself ships **no personal configuration** — it's a template repo
for the tooling only. You bring your own `home/` and `packages/*.txt`.

## What you get

- `install.sh` — symlinks your configs into `$HOME`, installs your tracked
  pacman/AUR packages, sets up the secret-scan git hook and the auto-sync
  timer. Idempotent, safe to re-run.
- `adopt.sh` — turns an existing real config file into a repo-tracked
  symlink (`--host` for machine-specific files).
- `check-adoptable.sh` — read-only: scans `$HOME` for well-known config
  paths (an explicit allowlist, see "Why adopt.sh refuses some paths"
  below) not yet tracked, and prints one `adopt.sh` command per candidate
  for you to review, so you don't have to hunt for them yourself on a new
  machine.
- `backup.sh` — auto-commits and pushes changes; run by a systemd user
  timer daily and ~5 minutes after login. Writes the status the bar widget
  reads.
- `check-drift.sh` — read-only: `packages/*.txt` vs. what's actually
  installed.
- `check-links.sh` — read-only: are all tracked configs still correctly
  symlinked?
- `clean-backups.sh` — cleans up `~/.dotstate-backup-*` dirs left behind by
  `install.sh`/`adopt.sh` once they're redundant.
- `githooks/pre-commit` — blocks a commit if `gitleaks` finds a likely
  secret in the staged changes.
- `manifest.json` + `Panel.qml` + `Model.js` — an Omarchy Quickshell
  bar-widget plugin (see below) that also drives first-time setup (create
  repo from template, clone, run `install.sh`) entirely from the bar, no
  terminal commands required. These live at the repo root, not in a
  subfolder, because `omarchy-plugin-validate` requires `manifest.json`
  directly at the root of whatever `omarchy plugin add` clones.

## Quickstart

**Bar-driven (recommended) — only one command, everything else is clicking:**

1. Click **"Use this template"** on this repo to create your own (can be
   private) dotfiles repo.
2. Add it as an Omarchy plugin — this is the one unavoidable terminal
   command, since it's how Omarchy loads any bar plugin in the first place:
   ```bash
   omarchy plugin add https://github.com/<you>/<your-dotfiles-repo>.git --enable --yes
   ```
3. Click the new Dotstate icon in your bar. Everything from here is guided
   in the panel: click **"Don't have a repo yet? Create one on GitHub"** if
   you skipped step 1, or paste your repo's URL and click **"Clone & set
   up"**. That clones it, runs `install.sh` for you, and saves the path —
   see [The bar widget](#the-bar-widget) below for exactly what it does and
   what it refuses to do. The only thing you might need to do by hand is
   answer a `sudo` password prompt or a git login in the terminal window it
   opens for that.

**Manual/CLI path**, if you'd rather drive it yourself:

```bash
git clone git@github.com:<you>/<your-dotfiles-repo>.git ~/Projects/dotfiles
cd ~/Projects/dotfiles
./check-adoptable.sh   # find well-known configs on this machine not tracked yet;
                        # review, then ./adopt.sh the ones you want, one at a time
./install.sh
```

## The bar widget

`manifest.json`/`Panel.qml`/`Model.js` at the repo root form an Omarchy
shell plugin (see the [Omarchy shell
docs](https://github.com/basecamp/omarchy/blob/quattro/shell/README.md)
for how plugins work in general, and step 2 of the Quickstart above for how
to add it). It shows an icon in your bar:

| Color | Meaning |
|---|---|
| Dim | Not configured yet, or no sync has run |
| Normal (foreground) | Last sync succeeded |
| Urgent | Last sync failed |

**Before a dotfiles repo is configured**, clicking it opens a guided setup
instead of a bare settings field: a link to create your own repo from this
template on GitHub, a field for that repo's git URL, a field for where to
clone it (defaults to `~/Projects/dotfiles`), and a **"Clone & set up"**
button that clones it and runs its `install.sh` for you in a terminal
window it opens itself — you only need to touch that window if it asks for
a `sudo` password or a git login. No command has to be typed or
copy-pasted, and nothing above this section needs to be read first.

**Important:** `omarchy plugin add` clones this repo into its own directory
under `~/.config/omarchy/plugins/`, separate from your actual working
checkout (e.g. `~/Projects/dotfiles`). Because of that, the widget doesn't
guess where your real repo is — and since pointing it at the plugin's own
checkout by mistake is exactly what has broken a desktop before (see [Why
install.sh refuses to relink some paths](#why-installsh-refuses-to-relink-some-paths)
below), it actively refuses to save a path under
`~/.config/omarchy/plugins/`, whether typed by hand or produced by the
guided clone flow.

**Once configured**, the panel instead shows:

- **Sync now** — triggers `backup.sh` immediately.
- **Run setup (install.sh)** — safe to re-run any time, e.g. after pulling
  changes made on another machine, or to repair broken symlinks.
- **Check package drift** / **Check symlinks** — read-only checks, output
  shown in a terminal window.
- **Find adoptable configs** — opens `check-adoptable.sh` in a terminal so
  you can review and adopt untracked configs without hunting for the
  script yourself.
- **Open repo** — opens your working checkout in your file manager.
- The **dotfiles repo path** field itself, still editable by hand if you'd
  rather manage it that way.

## Host-specific configs

Not every config should be identical on every machine (monitor layout,
CPU-specific packages, ...). Alongside `home/` (shared) you can add an
optional `home.<hostname>/` (hostname via the `hostname` command), which
`install.sh` links on top — it wins on overlap. Same idea for packages via
`packages/pacman.<hostname>.txt` / `packages/aur.<hostname>.txt`.

```bash
./adopt.sh --host ~/.config/hypr/monitors.lua
```

`home.<hostname>/` is purely additive — a new/renamed machine without an
overlay just gets `home/`, nothing breaks.

## Why adopt.sh refuses some paths

Early on, `check-adoptable.sh` suggested a directory that looked like a
plain config at the top level, but (because `install.sh` symlinks
individual files rather than whole directories) turned out to contain
files another dotfiles setup already managed. Adopting it whole broke
that management. Fixed by having both scripts detect and refuse any
symlink pointing outside the current repo, at any depth.

Separately, a broader test run adopted several top-level `~/.config/*`
entries at once, including some that weren't plain config at all: an
editor's cache/session-state directory and a CLI tool's login-token file
ended up committed and briefly pushed to a public remote. The original
`check-adoptable.sh` used a denylist of "known noise" to filter
suggestions — which can only ever list what it already knows to avoid,
and this is exactly what it missed.

Both scripts now work the other way around:

- `check-adoptable.sh` only ever suggests paths from a fixed **allowlist**
  of common, credential-free config locations (see `ALLOWLIST_*` at the
  top of the script) — extend it yourself for tools it doesn't know about.
  It also prints one `adopt.sh` command per candidate instead of a single
  "adopt everything" one-liner, so reviewing each one is the default path,
  not an extra step to skip.
- `adopt.sh` itself refuses, unconditionally and with no override flag,
  anything matching a hard blocklist of credential/state locations, a
  case-insensitive name pattern (`*token*`, `*credential*`, `*history*`,
  `*session*`, ...), or anything larger than 5MB — this applies no matter
  how the path was given to it, including typed by hand.

If you ever hit one of these refusals for something you're sure is a
plain config file, that's a false positive in a hardcoded list, not a
bug in the logic — adopt it manually (copy it into `home/`, symlink it
back, `git add`) instead of trying to force `adopt.sh` past the check.

## Why install.sh refuses to relink some paths

A separate incident: running this tooling on a machine that already had a
*different* dotfiles repo managing some of the same `$HOME` paths (e.g. a
private dotfiles repo alongside a Dotstate-based one, or `install.sh`
accidentally run from the Omarchy plugin checkout under
`~/.config/omarchy/plugins/` instead of the real working repo) let the
second run silently back up and relink whatever the first one already
owned — no warning, no confirmation. When that "other repo" was the
plugin checkout (which Omarchy can update or delete on its own schedule),
configs ended up pointing at a directory that no longer existed, which
took down the whole Hyprland session.

`install.sh` now refuses outright to run from inside
`~/.config/omarchy/plugins/`, and its symlinking step (`link_tree`) skips
— with a clear warning, not a silent takeover — any path that's already a
symlink into a *different* repo, the same protection `adopt.sh` already
had. There's no override flag here either: decide which repo should own
the path and remove the other's claim on it yourself first.

## Secret scan

`install.sh` points this repo's git hooks at `githooks/`. The `pre-commit`
hook runs `gitleaks` over staged changes and blocks the commit on a likely
secret (also applies to `backup.sh`'s automatic commits). Requires
`gitleaks` (tracked in `packages/pacman.common.txt`); if it's not
installed, the scan is skipped rather than blocking you. Bypass a
confirmed false positive once with `git commit --no-verify`.

## Automatic sync

`backup.sh` commits and pushes any changes (with a `git pull --rebase`
first, so multiple machines don't fight each other), run by the
`dotstate-backup.timer` systemd user timer that `install.sh` installs:
daily, plus ~5 minutes after login, catching up on missed runs if the
machine was off. Trigger it manually with:

```bash
systemctl --user start dotstate-backup.service
journalctl --user -u dotstate-backup.service   # logs
```

A failed run sends a desktop notification and leaves a status file at
`~/.cache/dotstate/status.json`, which [the bar widget](#the-bar-widget)
reads.

## CI

Every push runs `shellcheck` over all scripts and `gitleaks` over the full
git history (`.github/workflows/ci.yml`).

## License

MIT — see [LICENSE](LICENSE).
