# AGENTS.md

Quick reference for agent sessions in this repo.

One-click installer for the Rockchip platform web service
([wdnwebui](https://github.com/rockchip-wardner/wdnwebui)) and its SDKs / card
plugins. It ships the `wdn` CLI, the install scripts and the package list
the installer clones into the venv.

## Repo addresses and sync policy (2026-11-10)

| Role | Address | Allowed operations |
|---|---|---|
| **Intranet primary** | http://10.10.10.10:8080/wardner | **pull + push** — the single authoritative source, the first stop for every update |
| **GitHub** | https://github.com/rockchip-wardner | **push only** — the release mirror; never pull from it |
| **Gitee mirror** | https://gitee.com/rockchip-wardner | **no git operation at all** — a public read-only mirror, synced from upstream automatically |

Remote names: `origin` = `git@10.10.10.10:wardner/wardner.git` (intranet),
`github` = `git@github.com:rockchip-wardner/wardner.git` (push only).

**The push order must not be reversed: `git push origin master` (intranet primary)
first, then `git push github master` (GitHub). Never touch Gitee.** `master`
tracks `origin`, so a bare `git pull` / `git push` operates on the primary repo.
Pulling fresh code goes to the intranet primary only — pulling from GitHub
fetches "history that has already been released" and forks the local branch.

🚦 **Always ask the user before pushing (2026-11-12).**

A local `git commit` needs no permission; **`git push` always needs it** — push
only after the user says yes:

> "Shall I push these N commits of wardner to the intranet primary
> (10.10.10.10) and to GitHub?"

**Never push as a matter of course.** Reasons:

* Pushing is an outward-facing action — the GitHub mirror is public and
  internationally visible, and it cannot be taken back.
* The user may still have work in progress locally; pushing early publishes
  half-finished work as "the latest".
* One approval covers only the repository and the commits that were named in
  the question — do not roll it over to other repos.

The order itself is unchanged (intranet first, then GitHub); it just gains an
"ask first" step.

## Commit message policy (2026-11-11)

**Commit messages must be in English.**

- Format: Conventional Commits — `type(scope): subject`, body (if any) in English
  too. Example: `feat(cli): show the version of every component`
- Why: this repo is released to a public GitHub mirror (a release mirror is
  internationally visible), so the commit history is read by an international
  audience — Chinese commit messages make the public history unreadable.
- **This constrains commit messages only**: code comments, docstrings and the
  in-repo docs (AGENTS.md / README) keep the existing convention of this repo
  (Chinese is fine there).


## Repo map (one-line each)

- `cli/wdn.py` — the `wdn` CLI: `update` / `status` / `doctor` / `version` / `start` / `stop`.
- `bin/wdn` — bash launcher; resolves the symlink chain, finds the venv python and execs the CLI with it.
- `install.sh` — the one-shot installer; `install_github.sh` / `install_gitee.sh` — entry scripts that declare the source site.
- `packages.conf` — the package list (one line per package: directory name + GitHub repo name). Adding a package = add a line here + create the repo.
- `lib/` — shared shell helpers (`common.sh`, `urls.sh`).
- `update.sh` — pull the installer itself.
- `scripts/` — verification scripts.
