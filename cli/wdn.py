#!/usr/bin/env python3
"""wdn — the wardner command line tool.

Subcommands
-----------
  update    update every downloaded repo to the latest revision of the
            **source site** (GitHub / the Gitee mirror) and re-sync the venv
  status    list the local commit, the remote and the readiness of the venv
            for every repo
  doctor    check the system environment: the native .so files, the **system
            libraries of the hardware engines** (MPP / RGA / Mali / RKNN),
            the SDK versions, the dependency versions, the plugin registration
  start     start the wdnwebui service in the background and listen on the
            given port (default 8000)
  stop      stop the wdnwebui service
  version   print the version

Runs with the **venv python** (see bin/wdn)
--------------------------------------------
The CLI itself only depends on the standard library, but it runs under
`~/.wardner/wdnwebui/.venv/bin/python`, which has two advantages:

  * it can import the SDKs (wdnai / wdnav / …) directly and judge whether
    the installation is actually usable;
  * the smoke test after an update runs in the same interpreter — the
    environment before and after the update is the same one.

Why "fetch the code" and "install the packages" have to be separate
--------------------------------------------------------------------
Fetching the code changes the source tree, installing the packages changes
the .venv. An editable install means a pure Python package takes effect as
soon as it is fetched, but a package with a build hook (wdndds / wdnav)
**must be reinstalled** to recompile the .so — pulling without reinstalling
leaves you with new sources and an old .so.

The "pull + decide whether to reinstall" of the 8 SDK packages is delegated
to `update_rkwhl.sh` in the host repo, which decides based on the **HEAD
comparison before and after the pull**. ⚠️ The order must not be reversed:

    let update_rkwhl.sh pull first  →  it sees the HEAD changed → reinstall
                                       + recompile the .so
    if wdn pulls first              →  it sees the HEAD unchanged → skip the
                                       reinstall → the .so is not recompiled

So wdn only takes care of its own two repos (wardner / wdnwebui) and leaves
the SDK packages to update_rkwhl.sh — that HEAD comparison logic is not
reimplemented here.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Output
#
# The board has no emoji / symbol font: 🖼 ✕ ⚠ ✓ ☑ ▯ 🗑 📁 all render as tofu
# boxes (□). The only symbols that work on the board are `× ● ■ ▶ ← → ↑ ↓`
# — only those are used below.
# ---------------------------------------------------------------------------
_TTY = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
C_RED = "\033[1;31m" if _TTY else ""
C_GRN = "\033[1;32m" if _TTY else ""
C_YEL = "\033[1;33m" if _TTY else ""
C_BLU = "\033[1;34m" if _TTY else ""
C_DIM = "\033[2m" if _TTY else ""
C_RST = "\033[0m" if _TTY else ""


def step(msg: str) -> None:
    print(f"\n{C_BLU}▶ {msg}{C_RST}")


def ok(msg: str) -> None:
    print(f"  {C_GRN}●{C_RST} {msg}")


def warn(msg: str) -> None:
    print(f"  {C_YEL}×{C_RST} {msg}")


def bad(msg: str) -> None:
    print(f"  {C_RED}×{C_RST} {msg}")


def note(msg: str) -> None:
    print(f"  {C_DIM}{msg}{C_RST}")


def err(*lines: str) -> None:
    for line in lines:
        print(line, file=sys.stderr)


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------


def wardner_home() -> Path:
    """The install root (~/.wardner)."""
    env = os.environ.get("WARDNER_HOME")
    if env:
        return Path(env).expanduser().resolve()
    # cli/wdn.py → <wardner>/cli → <wardner> → <wardner_home>
    return Path(__file__).resolve().parent.parent.parent


def wardner_repo() -> Path:
    """The directory of this repo (the installer itself)."""
    return Path(__file__).resolve().parent.parent


def host_repo() -> Path:
    """The host application repo."""
    env = os.environ.get("WARDNER_HOST_REPO") or "wdnwebui"
    return wardner_home() / env


def venv_dir() -> Path:
    return host_repo() / ".venv"


def venv_python() -> Path:
    return venv_dir() / "bin" / "python"


def venv_src() -> Path:
    return venv_dir() / "src"


def site_packages() -> Path:
    """The site-packages of the venv this CLI runs in."""
    import sysconfig

    return Path(sysconfig.get_paths()["purelib"])


# ---------------------------------------------------------------------------
# git
#
# GIT_TERMINAL_PROMPT=0: when the remote is wrong git asks for a
#   username/password, which **hangs** waiting for input. Failing
#   immediately is better than hanging.
# lowSpeedLimit/lowSpeedTime: git has no connect timeout by default, a
#   TCP-level failure takes 135s to surface (observed: "Failed to connect
#   ... after 135137 ms"). Cap it at 30s.
# ---------------------------------------------------------------------------
GIT_ENV = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
GIT_NET = ["-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=30"]


def _git(args: list[str], cwd: Path, timeout: int = 300):
    try:
        return subprocess.run(
            ["git", *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=GIT_ENV,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", f"timed out (>{timeout}s)")


def git_out(args: list[str], cwd: Path) -> str:
    r = _git(args, cwd)
    return r.stdout.strip() if r.returncode == 0 else ""


def rev(repo: Path) -> str:
    return git_out(["rev-parse", "HEAD"], repo)


def short(sha: str) -> str:
    return sha[:7] if sha else "—"


def remote_of(repo: Path) -> str:
    return git_out(["remote", "get-url", "origin"], repo)


def list_remotes(repo: Path) -> list[tuple[str, str]]:
    """[(remote name, URL)]. The remote names are not consistent (origin /
    github / rk have all been seen)."""
    out: list[tuple[str, str]] = []
    r = _git(["remote"], repo)
    if r.returncode != 0:
        return out
    for line in r.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        name = parts[0]
        url = git_out(["remote", "get-url", name], repo)
        out.append((name, url))
    return out


def current_branch(repo: Path) -> str:
    return git_out(["rev-parse", "--abbrev-ref", "HEAD"], repo)


def tracked_remote(repo: Path, branch: str) -> str:
    """The name of the remote tracked by the current branch
    (branch.<br>.remote)."""
    if not branch:
        return ""
    return git_out(["config", "--get", f"branch.{branch}.remote"], repo)


def norm_remote(url: str) -> str:
    """Normalise a remote URL into a comparable form.

    The following spellings have to be equal after normalisation:
        git@github.com:org/repo.git
        ssh://git@github.com/org/repo.git
        https://github.com/org/repo.git

    Gitee is handled the same way — the source site is not only GitHub, so
    the normalisation must not be hardcoded per site.
    """
    u = (url or "").strip()
    if u.startswith("git+"):
        u = u[4:]
    if u.endswith(".git"):
        u = u[:-4]
    if u.startswith("ssh://"):
        u = u[len("ssh://"):]
    if u.startswith("git@"):
        # git@github.com:org/repo → github.com:org/repo
        u = u[4:].replace(":", "/", 1)
    for scheme in ("https://", "http://"):
        if u.startswith(scheme):
            u = u[len(scheme):]
            break
    return u.rstrip("/")


def host_of(url: str) -> str:
    """Derive the source host name from a remote URL, an empty string when
    it cannot be derived.

    Not limited to github.com — the Gitee mirror and an intranet GitLab
    have to be recognised as well.
    """
    parts = norm_remote(url).split("/")
    return parts[0] if parts and parts[0] else ""


def org_of(url: str) -> str:
    """Derive the org name from a remote URL, an empty string when it
    cannot be derived."""
    parts = norm_remote(url).split("/")
    if len(parts) >= 3:
        return parts[1]
    return ""


def repo_of(url: str, fallback: str = "") -> str:
    """Derive the repo name from a remote URL, `fallback` when it cannot be
    derived."""
    parts = norm_remote(url).split("/")
    if len(parts) >= 3 and parts[-1]:
        return parts[-1]
    return fallback


# Read-only mirror — the content is synced from upstream, a push gets
# overwritten.
#
# This is not a matter of style: pushing the wrong thing **loses code**. A
# commit pushed to a mirror is overwritten by the upstream version on the
# next sync, with no warning at all.
READONLY_HOSTS = {"gitee.com"}


def host_is_readonly(host: str) -> bool:
    return (host or "") in READONLY_HOSTS


def resolve_org() -> str:
    """The org used for this operation.

    The environment variable wins, then what is written in the remote of
    this repo (the remote is a fact, an inference is not).
    """
    env = os.environ.get("WARDNER_ORG")
    if env:
        return env
    return org_of(remote_of(wardner_repo())) or "rockchip-wardner"


def resolve_source_host() -> str:
    """The **source site** used for this operation (github.com / gitee.com /
    an intranet GitLab).

    The environment variable wins, then what is written in the remote of
    this repo — `wdn update` keeps going to the site you installed from
    (pulling GitHub is slow on mainland networks, which is exactly what the
    Gitee mirror is for).
    """
    env = os.environ.get("WARDNER_SOURCE_HOST")
    if env:
        return env
    return host_of(remote_of(wardner_repo())) or "github.com"


def source_scheme_for_host(host: str) -> str:
    """Source site → transport scheme.

    * **GitHub / Gitee use https** — public repos, anonymous clone is
      enough, no account / SSH key required. This is the only path that
      works for people who have never logged in.
    * **Intranet hosts use ssh** — the web port of an intranet GitLab is
      8080, which is an HTTP port; ssh is the right way to fetch the code.

    The scheme is decided by the **source site**, not by the scheme of the
    URL the script was downloaded from: the /raw/ pages of an intranet
    GitLab are served over http, but the code has to come over ssh.
    """
    return "https" if host in ("github.com", "gitee.com") else "ssh"


def clone_url_for(host: str, org: str, repo: str) -> str:
    """Build the clone URL for a source site (the scheme follows the site).

    The SSH host carries no port — the 8080 of the web UI is an HTTP port,
    not an SSH port.
    """
    if source_scheme_for_host(host) == "ssh":
        return f"git@{host.split(':')[0]}:{org}/{repo}.git"
    return f"https://{host}/{org}/{repo}.git"


def pull(repo: Path, dry_run: bool = False, retries: int = 5, delay: int = 5):
    """git pull --ff-only. Returns (before, after, ok, message)."""
    before = rev(repo)
    if dry_run:
        return before, before, True, "dry-run"

    last = ""
    for attempt in range(1, retries + 1):
        r = _git([*GIT_NET, "pull", "--ff-only"], repo)
        if r.returncode == 0:
            return before, rev(repo), True, ""
        blob = (r.stderr or r.stdout or "").strip()
        last = blob.splitlines()[-1] if blob else f"exit {r.returncode}"
        if attempt < retries:
            warn(f"git pull failed (attempt {attempt}/{retries}): {last}")
            time.sleep(delay)
    return before, rev(repo), False, last


def clone(url: str, dest: Path, dry_run: bool = False) -> bool:
    if dry_run:
        note(f"[dry-run] git clone {url} → {dest}")
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    r = _git([*GIT_NET, "clone", "--branch", "master", url, str(dest)], dest.parent)
    if r.returncode != 0:
        blob = (r.stderr or r.stdout or "").strip()
        bad(f"clone failed: {url}")
        if blob:
            for line in blob.splitlines()[-3:]:
                note(line)
        return False
    return True


# ---------------------------------------------------------------------------
# Package list
# ---------------------------------------------------------------------------

def read_packages_conf(repo: Path) -> list[tuple[str, str]]:
    """Read packages.conf → [(directory name, GitHub repo name)]."""
    path = repo / "packages.conf"
    if not path.is_file():
        return []
    out: list[tuple[str, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            out.append((parts[0], parts[1]))
    return out


# Push-only remote names — the URL of these remotes **must not** be aligned
# to the source site.
#
# The organisational policy (see "仓库地址与同步策略" in
# wdnwebui/AGENTS.md):
#   * the intranet primary repo = the authoritative source, pull + push
#   * GitHub                  = the release mirror, **push only**
#   * Gitee                   = nothing at all
#
# Rewriting the URL of `github` to the source site would silently turn the
# "release mirror" into "a copy of the primary repo" — when the user runs
# `git push github` they actually push back to the intranet, the release
# never happens, and **there is no warning at all**. This is the most
# insidious kind of "silently changing the push path".
PUSH_ONLY_REMOTES = {"github"}


def repo_name_of(repo: Path, fallback: str) -> str:
    """Derive the repo name from the remote URL."""
    return repo_of(remote_of(repo), fallback)


def _pushurl_of(repo: Path, rname: str) -> str:
    """The **explicit** value of remote.<r>.pushurl (an empty string when it
    is not set).

    When it is not set git uses the fetch URL as the push address — so an
    "empty string" means "the user never expressed the intent to push",
    and only then may we set one for them.
    """
    return git_out(["config", "--get", f"remote.{rname}.pushurl"], repo)


def _push_url_for(repo: Path, org: str, repo_name: str) -> str:
    """The push address this repo should use (it has to be a **writable**
    site).

    An existing writable remote of the repo is preferred (that keeps its
    protocol / authentication method, e.g. the SSH form of an intranet
    GitLab); without any, fall back to the https form of GitHub.
    """
    for _rname, url in list_remotes(repo):
        host = host_of(url)
        if host and not host_is_readonly(host):
            return url
    return f"https://github.com/{org}/{repo_name}.git"


def _sync_remotes(name: str, repo: Path, want_url: str, keep: bool = False,
                  dry_run: bool = False, push_url: str = "") -> None:
    """Align the remotes of a repo to the source site and make sure the
    pull really goes through the source site.

    ⚠️ The remote names are not consistent (origin / github / rk have all
       been seen), and `git pull` without arguments uses
       ``branch.<br>.remote`` — **changing only the URL of origin does not
       work**: on this board the master of the 8 packages tracks `github`
       (which already points at GitHub), while `origin` points at the
       intranet mirror; and there are repos that track the intranet one
       instead.

    The rules:

    * the URL of every remote points at the source site (intranet mirror →
      GitHub / Gitee);
    * the tracking relation is only moved to a remote that points at the
      source site when the tracked remote does not point at it — the
      tracking relation is also the push path of the user, changing it
      behind their back makes `git push` silently go somewhere else;
    * when the source site is a **read-only mirror** (Gitee), a separate
      pushurl points at a writable site: the fetch goes through the
      mirror (fast on mainland networks), the push goes to GitHub (the
      mirror is read-only, a push would be overwritten by the next sync).
    """
    want_key = norm_remote(want_url)
    want_host = host_of(want_url)
    want_host_label = "the Gitee mirror" if want_host == "gitee.com" else want_host
    readonly = host_is_readonly(want_host)

    # ① align the URLs (fetch)
    for rname, url in list_remotes(repo):
        if rname in PUSH_ONLY_REMOTES:
            # the release mirror that is push-only — leave its URL alone
            if dry_run:
                note(f"[dry-run] {name}: {rname} kept as is (push-only release mirror)")
            continue
        if norm_remote(url) != want_key and not keep:
            if dry_run:
                note(f"[dry-run] {name}: {rname} {url or '(empty)'} → {want_url}")
            elif _git(["remote", "set-url", rname, want_url], repo).returncode == 0:
                ok(f"{name}: {rname} {url or '(empty)'} → {want_url}")

        # ② read-only mirror: point the push path back at a writable site
        #
        # The pushurl is only set when the user has not set one — a pushurl
        # means the user expressed the intent to push, and changing that
        # behind their back is "silently changing the push path" as well.
        if readonly and push_url and not keep:
            if _pushurl_of(repo, rname):
                continue
            if dry_run:
                note(f"[dry-run] {name}: {rname} pushurl → {push_url}")
            elif _git(["remote", "set-url", "--push", rname, push_url], repo).returncode == 0:
                ok(f"{name}: {rname} push → {push_url} (the source site is a read-only mirror)")

    # ③ branch tracking
    br = current_branch(repo)
    if keep or not br or br == "HEAD":
        return

    remotes = list_remotes(repo)   # read the URLs again after changing them
    tracked = tracked_remote(repo, br)
    tracked_url = ""
    for rname, url in remotes:
        if rname == tracked:
            tracked_url = url
            break

    if tracked and norm_remote(tracked_url) == want_key:
        return   # already on the source site — leave the tracking relation alone

    # Pick a remote that points at the source site: HTTPS first (usable
    # anonymously)
    pick = ""
    for rname, url in remotes:
        if norm_remote(url) == want_key and url.startswith("https://"):
            pick = rname
            break
    if not pick:
        for rname, url in remotes:
            if norm_remote(url) == want_key:
                pick = rname
                break
    if not pick:
        pick = "origin"
        if dry_run:
            note(f"[dry-run] {name}: create the remote origin → {want_url}")
        elif _git(["remote", "add", "origin", want_url], repo).returncode == 0:
            ok(f"{name}: created the remote origin → {want_url}")

    if dry_run:
        note(f"[dry-run] {name}: branch {br} tracks {tracked or '(none)'} → {pick}")
        return
    _git(["config", f"branch.{br}.remote", pick], repo)
    if br == "master":
        _git(["config", f"branch.{br}.merge", "refs/heads/master"], repo)
    ok(f"{name}: branch {br} tracks {tracked or '(none)'} → {pick} ({want_host_label})")


# ---------------------------------------------------------------------------
# Subcommand: update
# ---------------------------------------------------------------------------

def cmd_update(args: argparse.Namespace) -> int:
    wrepo = wardner_repo()
    hrepo = host_repo()
    src = venv_src()
    vpy = venv_python()

    if not vpy.is_file():
        err(
            "[fail] not installed yet — the python of the venv was not found",
            f"       {vpy}",
            f"       run the installer once first: bash {wrepo}/install.sh",
        )
        return 2

    org = resolve_org()
    source_host = resolve_source_host()
    host_name = os.environ.get("WARDNER_HOST_REPO") or "wdnwebui"
    results: list[tuple[str, str, str, bool, str]] = []  # name, before, after, ok, msg

    step("Updating the repos")

    # ① update itself first — only then is packages.conf the latest
    before, after, good, msg = pull(wrepo, args.dry_run)
    results.append((repo_name_of(wrepo, wrepo.name), before, after, good, msg))
    if not good:
        bad(f"{wrepo.name} update failed: {msg}")

    # ② clone the packages that upstream added to packages.conf
    pkgs = read_packages_conf(wrepo)
    if pkgs:
        step("Filling in the missing packages")
        for pkg, repo_name in pkgs:
            dest = src / pkg
            if (dest / ".git").is_dir():
                continue
            note(f"{pkg} is missing — cloning")
            if not clone(clone_url_for(source_host, org, repo_name), dest, args.dry_run):
                bad(f"failed to fetch {pkg}")

    # ③ align the remotes to the source site
    #
    # "wdn update updates through the source site" is a hard requirement:
    # which site that is (GitHub / the Gitee mirror) is decided by the
    # **remote of this repo** — wherever it was installed from, the update
    # goes there as well. The branch tracking relation is only touched
    # when the tracked remote does not point at the source site — the
    # tracking relation is also the push path of the user, changing it
    # behind their back makes `git push` go somewhere else.
    step(f"Aligning the remotes to {source_host}")
    for name, path, repo_name in _all_repos(wrepo, hrepo, pkgs, host_name):
        if not (path / ".git").is_dir():
            continue
        _sync_remotes(
            name, path, clone_url_for(source_host, org, repo_name),
            keep=args.keep_remotes, dry_run=args.dry_run,
            push_url=_push_url_for(path, org, repo_name),
        )

    if host_is_readonly(source_host):
        warn(f"{source_host} is a read-only mirror (the content is synced from upstream automatically) — pulling/updating through it is fine,")
        warn("but **never push code to it**: push to GitHub or to the intranet primary repo.")
        warn("(the pushurl points at a writable site; wdn sets it when the user has not defined one)")

    # ④ pull the host application
    step("Pulling the latest code")
    before, after, good, msg = pull(hrepo, args.dry_run)
    results.append((host_name, before, after, good, msg))
    if good:
        if before == after:
            ok(f"{host_name}: {short(after)} (no change)")
        else:
            ok(f"{host_name}: {short(before)} → {short(after)}")
    else:
        bad(f"{host_name} update failed: {msg}")

    # ⑤ the 8 SDK packages — delegated to update_rkwhl.sh
    #
    # It pulls on its own (so that the HEAD comparison makes sense), and
    # when the HEAD changed it uninstalls, reinstalls + recompiles the .so,
    # and runs the .so landing assertions / the card registration checks /
    # the dependency audit.
    step("Syncing the SDK / plugin packages")
    pkg_before = {pkg: rev(src / pkg) for pkg, _ in pkgs if (src / pkg / ".git").is_dir()}

    script = hrepo / "update_rkwhl.sh"
    if not script.is_file():
        bad(f"not found: {script}")
        return 1
    if args.dry_run:
        note("[dry-run] skipping update_rkwhl.sh (it really pip installs)")
    else:
        # The package source prefix follows the source site (the scheme is
        # decided by the source site: GitHub/Gitee → https, intranet → ssh)
        if source_scheme_for_host(source_host) == "ssh":
            pkg_base = f"git+ssh://git@{source_host.split(':')[0]}/{org}"
        else:
            pkg_base = f"git+https://{source_host}/{org}"
        env = {**os.environ, "WARDNER_PKG_BASE": pkg_base}
        r = subprocess.run(
            ["bash", str(script)],
            cwd=str(hrepo),
            env=env,
            stdin=subprocess.DEVNULL,
        )
        if r.returncode != 0:
            bad(f"update_rkwhl.sh did not fully succeed (exit {r.returncode}) — see the log above")

    for pkg, _ in pkgs:
        p = src / pkg
        if not (p / ".git").is_dir():
            continue
        b = pkg_before.get(pkg, "")
        a = rev(p)
        results.append((pkg, b, a, True, ""))

    # ⑥ smoke test: the 4 SDKs must really be importable
    if not args.dry_run:
        step("Smoke test")
        _smoke()

    # ⑦ summary
    step("Summary")
    _print_results(results)

    if any(not good for _, _, _, good, _ in results):
        return 1
    return 0


def _all_repos(wrepo: Path, hrepo: Path, pkgs: list[tuple[str, str]], host_name: str):
    """(display name, path, expected GitHub repo name)"""
    out = [
        (repo_name_of(wrepo, wrepo.name), wrepo, repo_name_of(wrepo, wrepo.name)),
        (host_name, hrepo, host_name),
    ]
    for pkg, repo_name in pkgs:
        out.append((pkg, venv_src() / pkg, repo_name))
    return out


def _smoke() -> None:
    """Import the 4 SDKs with the python of the venv.

    This assertion has to exist: verify_outputs of update_rkwhl.sh simply
    `return 0` for wdnai / wdnhid (pure Python, no .so to assert), and
    audit_sdk_deps only checks "can the SDK-declared dependencies be used",
    not whether the package itself can be imported. A broken editable
    install (a .pth pointing at a path that does not exist) slips through
    every gate.
    """
    code = (
        "import importlib,sys\n"
        "bad=[]\n"
        "for m in ['wdnav','wdnai','wdndds','wdnhid']:\n"
        "    try:\n"
        "        importlib.import_module(m)\n"
        "        print('  import %s: ok' % m)\n"
        "    except Exception as e:\n"
        "        bad.append(m)\n"
        "        print('  import %s: FAILED (%s)' % (m, e))\n"
        "sys.exit(1 if bad else 0)\n"
    )
    r = subprocess.run(
        [sys.executable, "-c", code],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        bad("the SDK import check failed — the packages listed above are not installed properly")
        err(
            "[fail] the SDK import check did not pass",
            "       common cause: the .pth of an editable install points at a path that does not exist.",
            "       fix: delete the directory of the affected package and run wdn update again:",
            f"         rm -rf {venv_src()}/<package-name>",
        )


def _print_results(results) -> None:
    if not results:
        return
    width = max(len(name) for name, _, _, _, _ in results)
    for name, before, after, good, msg in results:
        if not good:
            print(f"  {name:<{width}}  {C_RED}{short(before)} → {short(after)}  failed{C_RST}")
            if msg:
                note(msg)
            continue
        if before and after and before != after:
            print(f"  {name:<{width}}  {short(before)} → {C_GRN}{short(after)}{C_RST}")
        else:
            print(f"  {name:<{width}}  {short(after)}")


# ---------------------------------------------------------------------------
# Subcommand: status
# ---------------------------------------------------------------------------

def cmd_status(args: argparse.Namespace) -> int:
    wrepo = wardner_repo()
    hrepo = host_repo()
    org = resolve_org()
    pkgs = read_packages_conf(wrepo)

    step("Repo status")
    rows = []
    for name, path, _ in _all_repos(wrepo, hrepo, pkgs, os.environ.get("WARDNER_HOST_REPO") or "wdnwebui"):
        if not (path / ".git").is_dir():
            rows.append((name, "—", "(not installed)"))
            continue
        br = current_branch(path)
        tr = tracked_remote(path, br)
        url = ""
        for rname, rurl in list_remotes(path):
            if rname == tr:
                url = rurl
                break
        rows.append((name, short(rev(path)), f"{tr or '-'} → {url or '(no remote)'}"))

    width = max(len(r[0]) for r in rows)
    for name, sha, rem in rows:
        print(f"  {name:<{width}}  {sha}  {C_DIM}{rem}{C_RST}")

    step("venv")
    vpy = venv_python()
    if not vpy.is_file():
        bad(f"not installed yet — {vpy} does not exist")
        return 1
    ver = subprocess.run(
        [str(vpy), "-c", "import sys;print('%d.%d.%d' % sys.version_info[:3])"],
        capture_output=True, text=True,
    ).stdout.strip()
    ok(f"{venv_dir()}  (Python {ver})")

    step("SDK")
    _smoke()
    return 0


# ---------------------------------------------------------------------------
# Subcommand: version
# ---------------------------------------------------------------------------

def cmd_version(args: argparse.Namespace) -> int:
    print(f"wdn {VERSION}")
    print(f"  install root  {wardner_home()}")
    print(f"  installer     {wardner_repo()}")
    print(f"  host app      {host_repo()}")
    print(f"  venv python   {venv_python()}")
    return 0


# ---------------------------------------------------------------------------
# Subcommands: start / stop
#
# The webui runs **detached** from the CLI: the CLI spawns it in its own
# session (setsid) with the output redirected to a log file, and records
# the PID in a pid file. `wdn stop` reads that file and signals the whole
# process group.
#
# Why not systemd? `wdn start` has to work as a plain user: the board's
# autostart unit needs root (see wdnwebui/install_autostart.sh) and a
# systemd *user* session is not guaranteed to be running on a board that
# is only reachable over ssh. A pid file + a process group behaves the
# same on every install.
#
# The compute_workers are spawned with ``start_new_session=True`` (see
# app/core/compute/registry.py) ⇒ they detach from our process group and
# survive the stop by design — the next boot adopts them over DDS. Same
# policy as the stale sweep in wdnwebui/run.py.
# ---------------------------------------------------------------------------

DEFAULT_PORT = 8000


def _service_dir() -> Path:
    """<wardner_home>/run — the pid file lives here."""
    return wardner_home() / "run"


def _pid_file() -> Path:
    return _service_dir() / "wdnwebui.pid"


def _log_file() -> Path:
    return wardner_home() / "logs" / "wdnwebui.log"


def _pid_alive(pid: int) -> bool:
    """Is the pid alive? A process we may not signal still counts."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _proc_cmdline(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    except OSError:
        return ""


def _port_holder(port: int) -> int | None:
    """The PID holding the TCP port in LISTEN, or None.

    Uses ``ss -tlnp`` (iproute2) — universal on Linux, and it avoids
    depending on lsof (not installed everywhere).
    """
    try:
        out = subprocess.run(
            ["ss", "-tlnp", f"sport = :{port}"],
            capture_output=True, text=True, timeout=3,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    m = re.search(r"pid=(\d+)", out.stdout)
    return int(m.group(1)) if m else None


def _http_ok(port: int, timeout: float = 2.0) -> bool:
    """GET /health on the local port — the real readiness probe.

    "the port is bound" is not enough: uvicorn binds before the app has
    finished booting, and a request that comes back 200 proves the whole
    stack (config, the app, the static files) is actually serving.
    """
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/health", timeout=timeout
        ) as resp:
            return resp.status == 200
    except Exception:
        return False


def _lan_ip() -> str:
    """The address of this board on the LAN (no traffic is sent).

    A UDP "connect" only picks the route — nothing is transmitted.
    """
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(0.5)
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def _read_pid_file() -> dict | None:
    p = _pid_file()
    if not p.is_file():
        return None
    try:
        data = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _service_processes() -> list[tuple[int, str]]:
    """The live wdnwebui processes of this repo: (pid, cmdline).

    Only the processes whose CWD is the host repo count — a wdnwebui of
    another checkout on the same board must not be touched.
    """
    hrepo = host_repo()
    try:
        root = str(hrepo.resolve())
    except OSError:
        root = str(hrepo)
    out: list[tuple[int, str]] = []
    try:
        pids = sorted(int(p) for p in os.listdir("/proc") if p.isdigit())
    except OSError:
        return out
    me = os.getpid()
    for pid in pids:
        if pid == me:
            continue
        cmd = _proc_cmdline(pid)
        if not cmd:
            continue
        if "run.py" not in cmd and "app.main:app" not in cmd:
            continue
        try:
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            continue
        if cwd != root:
            continue
        out.append((pid, cmd))
    return out


def _systemd_unit(pid: int) -> str | None:
    """The systemd unit that owns the process, if any."""
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            raw = f.read()
    except OSError:
        return None
    units = re.findall(r"([A-Za-z0-9_.@:-]+\.service)\b", raw)
    return units[-1] if units else None


def _orphan_workers() -> list[int]:
    """The compute_workers of this repo (they survive the stop by design)."""
    hrepo = host_repo()
    try:
        root = str(hrepo.resolve())
    except OSError:
        root = str(hrepo)
    out: list[int] = []
    try:
        pids = sorted(int(p) for p in os.listdir("/proc") if p.isdigit())
    except OSError:
        return out
    for pid in pids:
        cmd = _proc_cmdline(pid)
        if "compute_worker.py" not in cmd:
            continue
        try:
            if os.readlink(f"/proc/{pid}/cwd") != root:
                continue
        except OSError:
            continue
        out.append(pid)
    return out


def _ppid_of(pid: int) -> int | None:
    """The parent pid of the process, or None."""
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("PPid:"):
                    return int(line.split()[1])
    except (OSError, ValueError):
        return None
    return None


def _is_repo_process(pid: int) -> bool:
    """Is the pid one of this repo's webui processes?

    Used to tell "the port is held by a leftover of an earlier run"
    (which the stale sweep in wdnwebui/run.py reaps) from "the port is
    held by something else" (which the sweep would not touch).
    """
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return False
    try:
        root = str(host_repo().resolve())
    except OSError:
        root = str(host_repo())
    if cwd != root:
        return False
    cmd = _proc_cmdline(pid)
    # run.py — the reloader parent; app.main:app — the systemd unit;
    # multiprocessing.spawn — the uvicorn worker it forked.
    return any(k in cmd for k in ("run.py", "app.main:app", "multiprocessing.spawn"))


def _descendant_pids(pid: int) -> list[int]:
    """All descendants of the pid (children, grandchildren, …).

    ⚠️ **NOT** via ``/proc/<pid>/task/<pid>/children``: that file needs
    ``CONFIG_PROC_CHILDREN``, and the kernel of this board does **not**
    set it (verified in /boot/config: ``# CONFIG_PROC_CHILDREN is not
    set``) — the file simply does not exist, so a walk over it would
    silently return nothing and the caller would believe the process has
    no children.

    The parent relation is read from ``/proc/<pid>/status`` (PPid)
    instead: one scan of /proc, then the tree is built in memory.
    """
    children: dict[int, list[int]] = {}
    try:
        pids = sorted(int(p) for p in os.listdir("/proc") if p.isdigit())
    except OSError:
        return []
    for p in pids:
        ppid = _ppid_of(p)
        if ppid:
            children.setdefault(ppid, []).append(p)

    out: list[int] = []
    stack = list(children.get(pid, []))
    seen = {pid}
    while stack:
        cur = stack.pop()
        if cur in seen:
            continue
        seen.add(cur)
        out.append(cur)
        stack.extend(children.get(cur, []))
    return out


def _terminate_group(
    pid: int,
    port: int | None = None,
    exclusive_group: bool = True,
    grace: float = 15.0,
) -> bool:
    """Stop the service and wait until it is really gone.

    ``exclusive_group=True`` means "this process group belongs to the
    service alone" — that is the case for an instance started by
    ``wdn start`` (it is spawned with ``start_new_session=True``), so the
    whole group can be signalled.

    ``exclusive_group=False`` is for an instance that somebody else
    started: its process group may well contain an interactive shell, and
    signalling the group would take that shell down with it. There only
    the process itself and its descendants are signalled.

    The wait is on the **process tree**, not on the pid: the group leader
    is the shell wrapper, which dies at once, while uvicorn keeps the
    socket until its graceful shutdown is done (the app caps that at 10s
    — see ``timeout_graceful_shutdown`` in wdnwebui/run.py). Returning
    before the worker is gone would let the next `wdn start` fail with
    [Errno 98].

    The ``compute_worker`` processes are **not** signalled: they are
    spawned with their own session on purpose, they survive the stop and
    the next boot adopts them again over DDS (the same policy as the
    stale sweep in wdnwebui/run.py).

    Returns True when the service is really gone.
    """
    try:
        pgid = os.getpgid(pid)
    except (ProcessLookupError, PermissionError):
        pgid = pid
    # Never signal our own group — that would kill the CLI too.
    same_group = pgid == os.getpgid(0)
    group_ok = exclusive_group and not same_group

    # The tree is snapshotted **before** the kill: once the parent dies
    # its children are reparented to init, and the walk would not find
    # them any more — the wait would then be over while the server was
    # still shutting down.
    tree = [pid] + [p for p in _descendant_pids(pid)
                    if "compute_worker.py" not in _proc_cmdline(p)]

    def _signal_tree(sig: int) -> None:
        if group_ok:
            try:
                os.killpg(pgid, sig)
                return
            except (ProcessLookupError, PermissionError):
                pass
        # The reloader parent first: it shuts its worker down cleanly.
        for target in tree:
            try:
                os.kill(target, sig)
            except (ProcessLookupError, PermissionError):
                pass

    _signal_tree(signal.SIGTERM)

    deadline = time.time() + grace
    while time.time() < deadline:
        holder = _port_holder(port) if port else None
        alive = [p for p in tree if _pid_alive(p)]
        if not holder and not alive:
            return True
        time.sleep(0.2)

    # Something survived the grace period — take the port holder down
    # hard, then the rest of the tree. The holder is signalled *with* the
    # reloader: killing the worker alone would just make the reloader
    # spawn a new one and take the port back.
    holder = _port_holder(port) if port else None
    if holder:
        try:
            os.kill(holder, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    for target in tree:
        try:
            os.kill(target, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    if group_ok:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    time.sleep(0.5)

    if port:
        return _port_holder(port) is None
    return not any(_pid_alive(p) for p in tree)


def _ports_of_pid(pid: int) -> list[int]:
    """The TCP ports the pid is listening on."""
    try:
        out = subprocess.run(
            ["ss", "-tlnp"], capture_output=True, text=True, timeout=3,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    ports: list[int] = []
    for line in out.stdout.splitlines():
        if not re.search(rf"pid={pid}[,)]", line):
            continue
        fields = line.split()
        if len(fields) < 4 or ":" not in fields[3]:
            continue
        try:
            ports.append(int(fields[3].rsplit(":", 1)[1]))
        except ValueError:
            continue
    return ports


def _print_log_tail(log: Path, lines: int = 20) -> None:
    try:
        content = log.read_text(errors="replace").splitlines()
    except OSError:
        return
    if not content:
        return
    note(f"the last {min(lines, len(content))} lines of {log}:")
    for line in content[-lines:]:
        print(f"    {C_DIM}{line}{C_RST}")


def _print_service_urls(port: int) -> None:
    ip = _lan_ip()
    ok(f"the web UI is listening on http://{ip}:{port}/")
    if ip != "127.0.0.1":
        note(f"also reachable at http://127.0.0.1:{port}/")


def cmd_start(args: argparse.Namespace) -> int:
    port = args.port
    hrepo = host_repo()

    if not (1 <= port <= 65535):
        bad(f"invalid port: {port} (must be 1..65535)")
        return 2

    if not venv_python().is_file():
        bad("the venv is missing — run the installer first")
        return 1
    entry = hrepo / "run.py"
    if not entry.is_file():
        bad(f"the host app is missing: {entry}")
        return 1

    step(f"starting wdnwebui on port {port}")

    # --- is it already running? ---
    state = _read_pid_file()
    if state:
        pid = int(state.get("pid") or 0)
        if pid and _pid_alive(pid):
            running_port = state.get("port", port)
            if running_port == port:
                ok(f"wdnwebui is already running on port {port} (pid {pid})")
                _print_service_urls(port)
                return 0
            bad(f"wdnwebui is already running on port {running_port} (pid {pid})")
            note("stop it first:  wdn stop")
            return 1
        # a leftover pid file of a process that is gone
        _pid_file().unlink(missing_ok=True)

    # --- is the port taken by somebody else? ---
    holder = _port_holder(port)
    if holder:
        if _is_repo_process(holder):
            # A leftover of an earlier run. The stale sweep of
            # wdnwebui/run.py reaps it — let the start go through.
            note(f"port {port} is held by a leftover wdnwebui (pid {holder}) "
                 f"— it will be reaped")
        else:
            bad(f"port {port} is already in use by pid {holder}")
            note(_proc_cmdline(holder) or "(the cmdline is not readable)")
            note("pick another port, or stop that process first")
            return 1

    # --- spawn it ---
    # run.sh is the repo's own entry point: it brings up the USB HID
    # gadget first and then runs run.py. Fall back to run.py when the
    # wrapper is not there.
    if (hrepo / "run.sh").is_file():
        cmd = ["bash", str(hrepo / "run.sh"), "--port", str(port)]
    else:
        cmd = [str(venv_python()), str(entry), "--port", str(port)]

    log = _log_file()
    log.parent.mkdir(parents=True, exist_ok=True)
    banner = (f"===== wdn start {time.strftime('%Y-%m-%d %H:%M:%S')} "
              f": {' '.join(cmd)} =====\n")
    with open(log, "ab", buffering=0) as fh:
        fh.write(banner.encode())
        proc = subprocess.Popen(
            cmd,
            cwd=str(hrepo),
            stdin=subprocess.DEVNULL,
            stdout=fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,   # setsid → its own process group
            env={**os.environ, "PYTHONUNBUFFERED": "1"},
        )

    # --- wait until it serves ---
    deadline = time.time() + args.timeout
    healthy = False
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        if _http_ok(port):
            healthy = True
            break
        time.sleep(0.5)

    if proc.poll() is not None:
        bad(f"wdnwebui exited during the startup (exit code {proc.returncode})")
        _print_log_tail(log, 25)
        return 1

    if not healthy:
        if _port_holder(port):
            warn(f"the port is bound, but /health did not answer within "
                 f"{args.timeout:.0f}s — the app is probably still booting")
        else:
            bad(f"wdnwebui did not come up within {args.timeout:.0f}s")
            _print_log_tail(log, 25)
            return 1

    # --- record the pid ---
    _service_dir().mkdir(parents=True, exist_ok=True)
    _pid_file().write_text(json.dumps({
        "pid": proc.pid,
        "port": port,
        "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "log": str(log),
        "cmd": " ".join(cmd),
    }, indent=2) + "\n")

    ok(f"wdnwebui started (pid {proc.pid})")
    _print_service_urls(port)
    note(f"the log   {log}")
    note("stop it with:  wdn stop")
    return 0


def cmd_stop(args: argparse.Namespace) -> int:
    step("stopping wdnwebui")

    # (pid, label, exclusive_group, port_hint)
    targets: list[tuple[int, str, bool, int | None]] = []
    state = _read_pid_file()
    if state:
        pid = int(state.get("pid") or 0)
        if pid and _pid_alive(pid):
            # we started it → it has a session of its own → the whole
            # process group belongs to the service
            raw = state.get("port")
            port = int(raw) if raw else None
            targets.append((pid, f"wdnwebui (port {port or '?'})", True, port))
        # the pid file goes either way — a stale one is worse than none
        _pid_file().unlink(missing_ok=True)

    if not targets:
        # not started by `wdn start` — look for a webui of this repo.
        # Its process group may contain somebody else's shell, so only
        # the process and its descendants are signalled. The port is
        # unknown here → it is resolved from the process itself.
        for pid, _cmd in _service_processes():
            targets.append((pid, "wdnwebui", False, None))

    if not targets:
        ok("wdnwebui is not running")
        return 0

    # systemd owns it — don't fight the manager behind its back
    for pid, _label, _excl, _port in targets:
        unit = _systemd_unit(pid)
        if unit:
            warn(f"wdnwebui is managed by systemd ({unit})")
            note(f"stop it with:  sudo systemctl stop {unit}")
            return 1

    for pid, label, exclusive, port in targets:
        if port is None:
            # not started by us → ask the process which port it serves
            ports = _ports_of_pid(pid)
            port = ports[0] if ports else None
        if _terminate_group(pid, port, exclusive_group=exclusive):
            ok(f"stopped {label} (pid {pid})")
            if port:
                ok(f"port {port} is free")
        else:
            bad(f"could not stop {label} (pid {pid}) — kill it manually")
            if port:
                holder = _port_holder(port)
                bad(f"port {port} is still held by pid {holder}"
                    if holder else f"port {port} is still held")

    workers = _orphan_workers()
    if workers:
        note(f"{len(workers)} compute_worker process(es) are still alive "
             f"(they are adopted by the next boot — that is by design)")
    return 0


# ---------------------------------------------------------------------------
# Subcommand: doctor
#
# A health check for the whole installation. The question it answers is
# "is this board actually able to run the thing, and if not, what exactly
# is missing?" — with the emphasis on the three failure classes that are
# invisible until something breaks:
#
#   1. a native library is missing (the .so of wdndds / wdnav was never
#      built, or was deleted) — the Python import still works, the feature
#      only fails at runtime;
#   2. a version does not match (the source tree was pulled but the
#      package was not reinstalled → the .so is older than the sources;
#      a pinned dependency is not satisfied → a different API than the
#      one the SDK was written against);
#   3. a **system library of the hardware engine** is missing (the MPP /
#      RGA / Mali / RKNN runtime that apt provides) — the SDKs load them
#      lazily and swallow the error, so the import works and only the
#      video pipeline / the NPU is dead.
#
# The check is read-only: it never installs, never pulls and never
# modifies anything, so it is safe to run on a live board.
#
# ⚠️ It does not touch the hardware either: the libraries are resolved
#    with `ldd` (which never runs the library) instead of dlopen — the
#    NPU runtime would initialise the NPU driver on load, and that must
#    not happen next to a live session.
# ---------------------------------------------------------------------------

# The native libraries that have to be there after the install.
#
# ⚠️ update_rkwhl.sh::verify_outputs carries an **inline copy** of this table
#    — **changing one means changing the other**.
REQUIRED_SO = {
    "wdndds": ["libwdndds_idl.so", "libwdndds_cshim.so"],
    "wdnav": ["libshim_video.so"],
}

# The commands needed to build the .so — missing ones are a warning, not an
# error, as long as the .so is already there.
BUILD_CMDS = ["git", "cmake", "make", "cc", "patchelf"]

# The apt packages that provide them.
BUILD_PKGS = ["cmake", "build-essential", "patchelf", "libfoonathan-memory-dev"]

# The SDKs that have to be importable.
SDK_MODULES = ["wdnav", "wdnai", "wdndds", "wdnhid"]

_REQ_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*(.*)$")


def _parse_requirement(raw: str) -> tuple[str, str] | None:
    """A requirement line → (name, specifier)."""
    raw = (raw or "").split("#", 1)[0].strip()
    if not raw or raw.startswith("-"):
        return None
    raw = raw.split(";", 1)[0].strip()
    m = _REQ_RE.match(raw)
    if not m:
        return None
    return m.group(1), (m.group(3) or "").strip()


# The markers of the managed block that install.sh writes into the rc
# files — the same text as lib/common.sh (WARDNER_RC_BEGIN / _END).
WARDNER_RC_BEGIN = "# >>> wardner (wdn) >>>"
WARDNER_RC_END = "# <<< wardner (wdn) <<<"


def _rc_files() -> list[Path]:
    """The rc files the installer writes the PATH into.

    ~/.bashrc always, ~/.zshrc when it exists or when zsh is the login
    shell — a zsh shell never reads ~/.bashrc, so a block that only
    landed there leaves the command unusable.
    """
    home = Path.home()
    out = [home / ".bashrc"]
    if (home / ".zshrc").is_file() or os.environ.get("SHELL", "").endswith("zsh"):
        out.append(home / ".zshrc")
    return out


def _check_wdn_on_path() -> int:
    """Can the user run `wdn` directly?

    Two different things are checked:
      * the **rc files** — the install writes the PATH into them, and a
        missing block means the install did not reach that shell;
      * the **PATH of this shell** — a terminal that was already open
        when the install ran has not picked the block up yet.
    """
    problems = 0
    step("The wdn command")

    for rc in _rc_files():
        text = ""
        try:
            text = rc.read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
        if WARDNER_RC_BEGIN in text and WARDNER_RC_END in text:
            ok(f"{rc} — the managed block is there")
        else:
            warn(f"{rc} — no managed block: a shell that reads this file "
                 "will not find wdn")
            note(f"  re-run the installer: bash {wardner_repo() / 'install.sh'}")

    bindir = wardner_repo() / "bin"
    entries = [p for p in os.environ.get("PATH", "").split(os.pathsep) if p]
    if str(bindir) in entries:
        ok(f"on the PATH: {bindir}")
        return problems

    local_bin = Path.home() / ".local" / "bin"
    if str(local_bin) in entries and (local_bin / "wdn").exists():
        ok(f"on the PATH through the symlink: {local_bin / 'wdn'}")
        return problems

    warn("the wdn command is not on the PATH of this shell")
    note(f"  export PATH=\"{bindir}:$PATH\"")
    note("  or open a new terminal — the rc files are read when the shell starts")
    return problems


def _installed_version(name: str) -> str | None:
    """The version of an installed distribution, None when it is not
    installed."""
    import importlib.metadata as md

    try:
        return md.version(name)
    except md.PackageNotFoundError:
        return None


def _spec_satisfied(installed: str, spec: str) -> bool | None:
    """Does `installed` satisfy `spec`? None when it cannot be decided."""
    if not spec:
        return True
    try:
        from packaging.specifiers import SpecifierSet

        return installed in SpecifierSet(spec)
    except Exception:
        pass
    # Fallback without packaging: only an exact pin can be decided.
    m = re.match(r"^==\s*([^\s,]+)$", spec.strip())
    if m:
        return installed == m.group(1)
    return None


def _source_version(pkg_dir: Path) -> str:
    """The version declared in the pyproject.toml of the source tree."""
    pyproject = pkg_dir / "pyproject.toml"
    if not pyproject.is_file():
        return ""
    try:
        text = pyproject.read_text(encoding="utf-8")
    except OSError:
        return ""
    try:
        import tomllib

        data = tomllib.loads(text)
        return str(data.get("project", {}).get("version", "") or "")
    except Exception:
        m = re.search(r'^\s*version\s*=\s*"([^"]+)"', text, re.M)
        return m.group(1) if m else ""


def _find_so(name: str, pkg_dir: Path) -> Path | None:
    """Find a .so by name — in the source tree of the package or in the
    site-packages of the venv."""
    roots = [pkg_dir, site_packages()]
    for root in roots:
        if not root.is_dir():
            continue
        try:
            for p in root.rglob(name):
                if p.is_file():
                    return p
        except OSError:
            continue
    return None


def _lib_dirs(pkg_dir: Path, so: Path) -> list[str]:
    """The directories the dynamic linker has to search for this package.

    The .so is linked with a RUNPATH of ``$ORIGIN/lib``, but the packages
    ship their libraries in more than one place: the build output sits
    next to the .so (``_native/``), the bundled prebuilt binaries in
    ``native/lib/``. The SDKs resolve them at runtime by preloading the
    SONAMEs with ctypes — so a plain ``ldd`` would report "not found" for
    libraries that work perfectly well in production.

    Mirroring the search path of the runtime is what makes the ldd result
    meaningful.
    """
    dirs = [str(so.parent)]
    try:
        for p in pkg_dir.rglob("lib"):
            if p.is_dir():
                dirs.append(str(p))
    except OSError:
        pass
    return dirs


def _missing_shared_libs(so: Path, pkg_dir: Path) -> list[str]:
    """The shared libraries the .so needs but cannot find (ldd, with the
    search path of the package)."""
    ldd = shutil.which("ldd")
    if not ldd:
        return []
    env = dict(os.environ)
    extra = _lib_dirs(pkg_dir, so)
    old = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = ":".join([*extra, old] if old else extra)
    try:
        r = subprocess.run(
            [ldd, str(so)], capture_output=True, text=True, timeout=30,
            stdin=subprocess.DEVNULL, env=env,
        )
    except Exception:
        return []
    out = f"{r.stdout}\n{r.stderr}"
    return [ln.strip() for ln in out.splitlines() if "not found" in ln]


def _human_size(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} GB"


def _check_system() -> int:
    """The system the board runs on, and the state of the install root."""
    import platform

    problems = 0
    step("System")
    ok(f"{platform.system()} {platform.release()} ({platform.machine()})")
    ok(f"Python {platform.python_version()} — {sys.executable}")

    vpy = venv_python()
    if vpy.is_file():
        ok(f"venv python: {vpy}")
    else:
        bad(f"the venv python is missing: {vpy}")
        problems += 1

    home = wardner_home()
    if home.is_dir():
        if os.access(home, os.W_OK):
            ok(f"install root is writable: {home}")
        else:
            bad(f"the install root is not writable: {home}")
            problems += 1
    else:
        bad(f"the install root does not exist: {home}")
        problems += 1

    try:
        usage = shutil.disk_usage(home if home.is_dir() else Path.home())
        free_gb = usage.free / (1024 ** 3)
        if free_gb < 1:
            bad(f"only {free_gb:.1f} GB free on {usage.total // (1024 ** 3)} GB disk")
            problems += 1
        else:
            ok(f"free disk space: {free_gb:.1f} GB")
    except OSError:
        pass
    return problems


def _check_toolchain() -> int:
    """The build toolchain — needed to (re)build the .so."""
    problems = 0
    step("Build toolchain")
    missing_cmds = []
    for cmd in BUILD_CMDS:
        path = shutil.which(cmd)
        if path:
            ok(f"{cmd}: {path}")
        else:
            missing_cmds.append(cmd)
    if missing_cmds:
        warn(f"missing commands: {', '.join(missing_cmds)}")
        note("  they are only needed to build the .so; run the installer again as root to get them:")
        note("  apt-get install -y cmake build-essential patchelf libfoonathan-memory-dev")
        problems += 1

    dpkg = shutil.which("dpkg")
    if dpkg:
        missing_pkgs = []
        for pkg in BUILD_PKGS:
            r = subprocess.run(
                [dpkg, "-s", pkg], capture_output=True, text=True,
                stdin=subprocess.DEVNULL,
            )
            if r.returncode != 0:
                missing_pkgs.append(pkg)
        if missing_pkgs:
            warn(f"missing apt packages: {', '.join(missing_pkgs)}")
            note("  apt-get update && apt-get install -y " + " ".join(missing_pkgs))
            problems += 1
        else:
            ok("all apt packages of the build toolchain are installed")
    return problems


def _check_native_libs(pkgs: list[tuple[str, str]]) -> int:
    """Do the native libraries exist, and can they be loaded?"""
    problems = 0
    step("Native libraries (.so)")

    found_any = False
    for pkg, _ in pkgs:
        wanted = REQUIRED_SO.get(pkg)
        if not wanted:
            continue
        pkg_dir = venv_src() / pkg
        if not pkg_dir.is_dir():
            bad(f"{pkg}: the source tree is missing ({pkg_dir})")
            problems += 1
            continue
        for so_name in wanted:
            so = _find_so(so_name, pkg_dir)
            if so is None:
                bad(f"{so_name}: missing — the feature that needs it will not work")
                problems += 1
                continue
            found_any = True
            try:
                size = _human_size(so.stat().st_size)
            except OSError:
                size = "?"
            missing = _missing_shared_libs(so, pkg_dir)
            if missing:
                bad(f"{so_name}: present ({size}) but {len(missing)} shared librar"
                    f"{'y' if len(missing) == 1 else 'ies'} not found")
                for m in missing:
                    note(f"  {m}")
                problems += 1
            else:
                ok(f"{so_name}: present ({size}) — {so}")

    if not found_any:
        note("rebuild them with: bash " + str(host_repo() / "update_rkwhl.sh"))
    return problems


# ---------------------------------------------------------------------------
# The hardware: the system libraries the SDKs load at runtime
#
# They are **not** part of the wheels — apt provides them. A missing one
# does not break the import (the SDKs load the libraries lazily and
# swallow the error), it breaks the *feature* — and only when the feature
# is used:
#
#   wdnav  VideoCapture    → MPP (hw codec) + RGA (colour conversion)
#   wdnav  SurfaceComposer → Mali (GPU) through the C shim
#   wdnai  the cshim       → librknn3_api.so (RKNN3) / librknnrt.so (RKNN2)
#
# That is the class of failure the doctor has to catch: everything
# imports, the app starts, and only the video pipeline / the NPU is dead.
# ---------------------------------------------------------------------------

# package → [(soname, apt package, what it is for, optional)]
#
# "optional" = the SDK has a fallback when the library is missing → a
# note, not a problem.
SYSTEM_LIBS: dict[str, list[tuple[str, str, str, bool]]] = {
    "wdnav": [
        ("librockchip_mpp.so.0", "librockchip-mpp1",
         "VPU hardware codec (hw decode / encode)", False),
        ("librga.so.2", "librga2",
         "RGA2 colour conversion / scaling", False),
        ("libmali.so", "libmali-valhall-g610-g24p0-x11-wayland-gbm",
         "GPU (EGL / GLES) offscreen rendering", False),
        ("libfreetype.so.6", "libfreetype6",
         "text rasterisation (the Typer of SurfaceComposer)", False),
        ("libv4l2.so.0", "libv4l2-0",
         "the V4L2 helper library (the v4l2 python package talks raw ioctl)", True),
    ],
    "wdnai": [
        ("librknn3_api.so", "rknn3-rk182x-sodimm",
         "RKNN3 NPU runtime — the only hard dependency of the cshim", False),
        ("librknn3_api_rkcp.so", "rknn3-rk182x-sodimm",
         "RKNN3 PCIe back-end (the RK182x co-processor cards)", True),
        ("librknnrt.so", "rknn2-runtime",
         "RKNN2 NPU runtime (the on-board NPU) — without it the VAE falls "
         "back to the slower rknn3 chain", True),
        ("librknnsmi.so", "rknn3-rk182x-sodimm",
         "NPU topology query (RKNN3 SMI)", True),
    ],
}

# The C shims that are compiled from the sources at install time (they are
# gitignored build artifacts — a fresh clone has none of them):
#   package → {shim: (mandatory, remedy)}
#
# libshim_video.so is not listed here — it is in REQUIRED_SO, the native
# section checks it (including its DT_NEEDED chain).
#
# libshim_mali.so is not mandatory for the *package* (the video path does
# not need it), but without it the GPU features (SurfaceComposer / Typer)
# are silently None — wdnav swallows the OSError of the dlopen.
SHIM_SO: dict[str, dict[str, tuple[bool, str]]] = {
    "wdnav": {
        "libshim_mali.so": (False, (
            "the GPU features (SurfaceComposer / Typer) need it — the shim is compiled\n"
            "  from src/wdnav/cshim_mali.c and needs the EGL / GLES / freetype headers:\n"
            "    sudo apt-get install -y libegl-dev libgles2-mesa-dev libfreetype-dev\n"
            "    .venv/bin/pip install --force-reinstall --no-deps .venv/src/wdnav")),
    },
    "wdnai": {
        "libqi_qwen.so": (False, ""),
    },
}


def _lib_search_dirs() -> list[str]:
    """The directories the dynamic linker searches on this board."""
    import sysconfig

    dirs = ["/usr/lib", "/usr/local/lib", "/lib", "/opt/lib"]
    multi = sysconfig.get_config_var("MULTIARCH")   # aarch64-linux-gnu
    if multi:
        dirs += [f"/usr/lib/{multi}", f"/lib/{multi}", f"/usr/local/lib/{multi}"]
    # the Rockchip GPU driver installs into a directory of its own
    dirs.append("/usr/lib/aarch64-linux-gnu/mali")
    return dirs


def _find_system_lib(soname: str) -> Path | None:
    """The file that provides `soname`.

    The exact name first (``/usr/lib/librknn3_api.so``), then the
    versioned sibling (``librga.so.2`` → ``librga.so.2.1.0``): apt
    installs the soname as a symlink, the versioned file is the one that
    carries the real version.
    """
    dirs = _lib_search_dirs()
    for d in dirs:
        p = Path(d) / soname
        if p.is_file():
            return p
    if ".so" in soname:
        prefix = soname[: soname.index(".so") + 3]
        for d in dirs:
            try:
                for p in sorted(Path(d).glob(prefix + ".*")):
                    if p.is_file() and p.name.startswith(soname + "."):
                        return p
            except OSError:
                continue
    return None


def _apt_versions(packages: list[str]) -> dict[str, str]:
    """{apt package: installed version} — only the installed ones."""
    dpkg = shutil.which("dpkg-query")
    if not dpkg:
        return {}
    out: dict[str, str] = {}
    for pkg in packages:
        try:
            r = subprocess.run(
                [dpkg, "-W", "-f=${Package}\t${Version}\n", pkg],
                capture_output=True, text=True, timeout=20,
                stdin=subprocess.DEVNULL,
            )
        except Exception:
            continue
        if r.returncode != 0:
            continue
        for line in r.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 2:
                out[parts[0]] = parts[1]
    return out


def _unresolved_deps(path: Path) -> list[str]:
    """The dependencies of a shared library that the linker cannot resolve.

    `ldd` resolves the DT_NEEDED entries **without** running the library —
    that matters here: dlopen'ing the NPU runtime would initialise the
    NPU driver, and a health check must not touch the hardware of a live
    session. The DT_NEEDED chain of the shims is what ties the system
    libraries to the SDKs anyway.
    """
    ldd = shutil.which("ldd")
    if not ldd:
        return []
    try:
        r = subprocess.run(
            [ldd, str(path)], capture_output=True, text=True, timeout=30,
            stdin=subprocess.DEVNULL,
        )
    except Exception:
        return []
    out = f"{r.stdout}\n{r.stderr}"
    return [ln.strip() for ln in out.splitlines() if "not found" in ln]


def _real_path(p: Path) -> Path:
    """The file behind a symlink — the versioned file carries the version."""
    try:
        return p.resolve(strict=False)
    except OSError:
        return p


def _check_hardware_libs(pkgs: list[tuple[str, str]]) -> int:
    """The system libraries the SDKs load at runtime."""
    problems = 0
    step("Hardware libraries")

    installed = {p for p, _ in pkgs}
    order = [p for p, _ in pkgs]          # the order of packages.conf
    specs = [(pkg, spec) for pkg in order for spec in SYSTEM_LIBS.get(pkg, [])]
    shims = [(pkg, name, meta) for pkg in order
             for name, meta in SHIM_SO.get(pkg, {}).items()]
    if not specs and not shims:
        warn("no system library is declared for the installed packages")
        return 0

    versions = _apt_versions(sorted({spec[1] for _, spec in specs}))
    width = max([len(p) for p, _ in specs] + [len(p) for p, _, _ in shims])

    for pkg, (soname, apt_pkg, purpose, optional) in specs:
        label = f"{pkg:<{width}}  {soname}"
        found = _find_system_lib(soname)
        if found is None:
            if optional:
                warn(f"{label} — not installed (optional: {purpose})")
            else:
                bad(f"{label} — MISSING ({purpose})")
                note(f"  install it: sudo apt-get install -y {apt_pkg}")
                problems += 1
            continue

        ver = versions.get(apt_pkg, "")
        tail = f"  ({apt_pkg} {ver})" if ver else f"  (not from {apt_pkg})"
        unresolved = _unresolved_deps(found)
        if unresolved:
            bad(f"{label} → {_real_path(found)}{tail}")
            note(f"  {len(unresolved)} unresolved dependenc"
                 f"{'y' if len(unresolved) == 1 else 'ies'}:")
            for m in unresolved:
                note(f"  {m}")
            problems += 1
        elif not ver:
            warn(f"{label} → {_real_path(found)}{tail}")
        else:
            ok(f"{label} → {_real_path(found)}{tail}")

    for pkg, name, (mandatory, remedy) in shims:
        label = f"{pkg:<{width}}  {name}"
        so = _find_so(name, venv_src() / pkg)
        if so is None:
            if mandatory:
                bad(f"{label} — the shim was not built")
                problems += 1
            else:
                warn(f"{label} — not built")
            if remedy:
                note(remedy)
            else:
                note("  rebuild it: bash " + str(host_repo() / "update_rkwhl.sh"))
            continue
        unresolved = _unresolved_deps(so)
        if unresolved:
            bad(f"{label} → {so}")
            note(f"  {len(unresolved)} unresolved dependenc"
                 f"{'y' if len(unresolved) == 1 else 'ies'}:")
            for m in unresolved:
                note(f"  {m}")
            problems += 1
        else:
            ok(f"{label} → {so}")
    return problems


# The capabilities the SDKs expose through their module attributes. The
# SDKs set the attribute to None when the library behind it could not be
# loaded — so the attribute **is** the report of the hardware chain.
#
#   wdnav.VideoCapture    → MPP + RGA
#   wdnav.SurfaceComposer → Mali (GPU) through the C shim
#   wdnav.Typer           → Mali (GPU) + freetype
#   wdnav.MediaDevice     → media-ctl in PATH
#
# "mandatory" = the feature is part of the SDK's contract.
CAPABILITIES = [
    ("wdnav", "VideoCapture", True, "the hardware video codec (MPP) + RGA"),
    ("wdnav", "SurfaceComposer", True, "the GPU (Mali) offscreen rendering"),
    ("wdnav", "Typer", True, "the GPU text rendering (Mali + freetype)"),
    ("wdnav", "MediaDevice", False, "the media-ctl based device graph"),
]


def _check_hardware_capabilities() -> int:
    """Can the SDKs really use the hardware?

    The import of an SDK does **not** open the hardware: wdnav loads the
    libraries inside a try/except and sets the class to None when that
    fails. So "import wdnav: ok" says nothing about the MPP / RGA /
    Mali chain — only the attributes do.

    The probe runs in a child process: loading the libraries has side
    effects (the RGA library writes a banner to stdout when the
    interpreter tears down), and a crashing library must not take the
    doctor down with it.
    """
    problems = 0
    step("Hardware capabilities")

    import json

    marker = "__WDN_CAP_RESULT__"
    code = (
        "import json,sys\n"
        "spec=json.loads(sys.argv[1])\n"
        "out={}\n"
        "for mod,attrs in spec:\n"
        "    try:\n"
        "        m=__import__(mod)\n"
        "    except Exception as e:\n"
        "        out[mod]='%s: %s' % (type(e).__name__, e)\n"
        "        continue\n"
        "    out[mod]='ok'\n"
        "    for a in attrs:\n"
        "        out[mod+'.'+a]='ok' if getattr(m,a,None) is not None else 'unavailable'\n"
        "sys.stderr.write('\\n' + sys.argv[2] + json.dumps(out))\n"
    )
    spec = json.dumps([["wdnav", [a for _, a, _, _ in CAPABILITIES]], ["wdnai", []]])
    try:
        r = subprocess.run(
            [sys.executable, "-c", code, spec, marker],
            capture_output=True, text=True, timeout=120,
            stdin=subprocess.DEVNULL,
        )
        blob = r.stderr.strip().splitlines()
        line = next((ln for ln in reversed(blob) if ln.startswith(marker)), "")
        res = json.loads(line[len(marker):]) if line else {}
    except Exception as e:
        bad(f"could not run the capability probe: {e}")
        return 1

    if not res:
        bad("the capability probe did not report anything")
        problems += 1

    for mod, attr, mandatory, purpose in CAPABILITIES:
        key = f"{mod}.{attr}"
        state = res.get(key)
        if state == "ok":
            ok(f"{key} — {purpose}")
        elif state == "unavailable":
            if mandatory:
                bad(f"{key} — unavailable ({purpose})")
                note("  the library behind it could not be loaded — see the "
                     "hardware libraries above")
                problems += 1
            else:
                warn(f"{key} — unavailable ({purpose})")
        elif state is None:
            warn(f"{key} — could not be determined ({res.get(mod, 'no answer')})")
        else:
            bad(f"{key} — {state}")
            problems += 1

    # The NPU runtime is loaded lazily, so the import of wdnai proves
    # nothing about it — the libraries above are the evidence.
    if res.get("wdnai") == "ok":
        ok("wdnai — imported (the RKNN3 runtime itself is loaded lazily)")
    elif "wdnai" in res:
        bad(f"wdnai — {res['wdnai']}")
        problems += 1
    return problems


# The device nodes the hardware engines need. The library without its
# node is still broken: the dlopen succeeds, the first ioctl fails.
HARDWARE_NODES = [
    ("/dev/mpp_service", "VPU — the hardware codec", True),
    ("/dev/rga", "RGA2 — the 2D accelerator", True),
    ("/dev/mali0", "Mali — the GPU", True),
]


def _rknn_device() -> str:
    """The device node the rknn2 runtime opens.

    The RKNPU driver registers a DRM card (``/dev/dri/cardN``) and the
    runtime opens it through that path (``/dev/dri/%s``); the legacy
    misc node ``/dev/rknpu`` is the fallback. Which card is the NPU is
    **not** a fixed number — it is the one the RKNPU driver is bound to,
    so the driver is looked up in sysfs instead of guessing card1 (on
    this board card0 is the display).
    """
    drm = Path("/sys/class/drm")
    if drm.is_dir():
        for card in sorted(drm.glob("card*")):
            try:
                uevent = (card / "device" / "uevent").read_text()
            except OSError:
                continue
            if "DRIVER=RKNPU" in uevent:
                return f"/dev/dri/{card.name}"
    if Path("/dev/rknpu").exists():
        return "/dev/rknpu"
    return ""


def _check_hardware_nodes() -> int:
    """The device nodes of the hardware engines.

    The libraries can be installed while the driver is missing — that is
    the second half of the "the video pipeline does nothing" failure.
    """
    problems = 0
    step("Hardware nodes")

    nodes = [(p, w, r) for p, w, r in HARDWARE_NODES]
    rknn = _rknn_device()
    if rknn:
        nodes.append((rknn, "the on-board NPU (rknn2)", True))

    for path, what, required in nodes:
        if not os.path.exists(path):
            if required:
                bad(f"{path} — missing ({what})")
                problems += 1
            else:
                warn(f"{path} — missing ({what}) — optional")
            continue
        # The nodes belong to root:video — a user outside that group gets
        # EACCES at the first ioctl, long after the import succeeded.
        if not os.access(path, os.R_OK | os.W_OK):
            warn(f"{path} — {what} — the current user cannot open it")
            continue
        ok(f"{path} — {what}")

    if not rknn:
        warn("no RKNPU device found (a /dev/dri/card* bound to the RKNPU "
             "driver, or the legacy /dev/rknpu): the rknn2 runtime is "
             "installed but cannot open the NPU")

    # The DMA heaps are a **directory** of device nodes: the directory
    # only has to be traversable, the nodes inside have to be writable.
    heaps = Path("/dev/dma_heap")
    if not heaps.is_dir():
        warn("/dev/dma_heap — missing (the zero-copy paths) — optional")
    elif not os.access(heaps, os.X_OK | os.R_OK):
        warn("/dev/dma_heap — the current user cannot traverse it")
    else:
        nodes = sorted(p for p in heaps.iterdir() if p.is_char_device())
        if not nodes:
            warn("/dev/dma_heap — the directory holds no DMA heap node")
        else:
            blocked = [p.name for p in nodes if not os.access(p, os.R_OK | os.W_OK)]
            if blocked:
                warn(f"/dev/dma_heap — the current user cannot open: "
                     f"{', '.join(blocked)}")
            else:
                ok(f"/dev/dma_heap — the DMA heaps "
                   f"({', '.join(p.name for p in nodes)})")

    # The NPU co-processor cards (the RK1828 PCIe cards) register a misc
    # device each.
    misc = Path("/sys/class/misc")
    cards = sorted(p.name for p in misc.glob("pcie-rkep-*")) if misc.is_dir() else []
    if cards:
        ok(f"the NPU co-processor cards: {len(cards)} ({', '.join(cards)})")
    else:
        warn("no NPU co-processor card found (/sys/class/misc/pcie-rkep-*)")
    return problems


def _check_sdk_imports() -> int:
    """Can the SDKs really be imported?"""
    problems = 0
    step("SDK imports")
    # The result is printed behind a marker: importing the SDKs makes
    # librga write a native banner to stdout when the interpreter tears
    # down, so the plain stdout cannot be parsed as JSON.
    marker = "__WDN_IMPORT_RESULT__"
    code = (
        "import importlib,json,sys\n"
        "out={}\n"
        "for m in %r:\n"
        "    try:\n"
        "        importlib.import_module(m); out[m]='ok'\n"
        "    except Exception as e:\n"
        "        out[m]='%%s: %%s' %% (type(e).__name__, e)\n"
        "sys.stderr.write('\\n%s' + json.dumps(out))\n" % (SDK_MODULES, marker)
    )
    try:
        r = subprocess.run(
            [sys.executable, "-c", code],
            capture_output=True, text=True, timeout=120,
            stdin=subprocess.DEVNULL,
        )
        import json

        blob = r.stderr.strip().splitlines()
        line = next((ln for ln in reversed(blob) if ln.startswith(marker)), "")
        res = json.loads(line[len(marker):]) if line else {}
    except Exception as e:
        bad(f"could not run the import check: {e}")
        return 1

    for m in SDK_MODULES:
        state = res.get(m, "unknown")
        if state == "ok":
            ok(f"import {m}: ok")
        else:
            bad(f"import {m}: FAILED ({state})")
            problems += 1
    return problems


def _check_sdk_versions(pkgs: list[tuple[str, str]]) -> int:
    """Does the installed version match the version of the source tree?

    A mismatch means the source tree was pulled but the package was not
    reinstalled — the .so is then older than the sources that should
    produce it.
    """
    problems = 0
    step("SDK versions")
    for pkg, _ in pkgs:
        installed = _installed_version(pkg)
        source = _source_version(venv_src() / pkg)
        if installed is None:
            bad(f"{pkg}: not installed")
            problems += 1
            continue
        if not source:
            ok(f"{pkg}: {installed} (the source tree declares no version)")
            continue
        if installed == source:
            ok(f"{pkg}: {installed}")
        else:
            bad(f"{pkg}: installed {installed} but the source tree declares {source}")
            note("  the installed package is stale — reinstall it:")
            note(f"  bash {host_repo() / 'update_rkwhl.sh'}")
            problems += 1
    return problems


def _check_requirement_versions() -> int:
    """Do the installed dependencies satisfy requirements.txt?"""
    problems = 0
    step("Dependency versions")
    req = host_repo() / "requirements.txt"
    if not req.is_file():
        warn(f"requirements.txt not found: {req}")
        return 0

    try:
        lines = req.read_text(encoding="utf-8").splitlines()
    except OSError as e:
        warn(f"cannot read {req}: {e}")
        return 0

    checked = 0
    for line in lines:
        parsed = _parse_requirement(line)
        if not parsed:
            continue
        name, spec = parsed
        installed = _installed_version(name)
        if installed is None:
            bad(f"{name}: not installed" + (f" (requirements.txt wants {spec})" if spec else ""))
            problems += 1
            continue
        checked += 1
        if not spec:
            ok(f"{name} {installed}")
            continue
        verdict = _spec_satisfied(installed, spec)
        if verdict is True:
            ok(f"{name} {installed} (matches {spec})")
        elif verdict is False:
            bad(f"{name} {installed} — requirements.txt wants {spec}")
            note(f"  .venv/bin/pip install '{name}{spec}'")
            problems += 1
        else:
            warn(f"{name} {installed} — cannot verify against {spec} (installing packaging would help)")
    if checked == 0:
        warn("no requirement could be checked")
    return problems


def _check_declared_deps() -> int:
    """The dependencies the SDKs declare — audited by the script that
    update_rkwhl.sh uses."""
    problems = 0
    step("Declared SDK dependencies")
    checker = host_repo() / "scripts" / "check_sdk_deps.py"
    if not checker.is_file():
        warn(f"the audit script is missing: {checker}")
        return 0
    try:
        r = subprocess.run(
            [sys.executable, str(checker), "--quiet"],
            cwd=str(host_repo()), capture_output=True, text=True,
            timeout=300, stdin=subprocess.DEVNULL,
        )
    except Exception as e:
        warn(f"could not run the audit: {e}")
        return 0
    if r.returncode == 0:
        ok("every declared dependency is installed and importable")
    else:
        bad("the dependency audit did not pass (see the details above)")
        for line in (r.stdout or "").splitlines()[-12:]:
            note(line)
        problems += 1
    return problems


def _check_plugins(pkgs: list[tuple[str, str]]) -> int:
    """Are the cards of the plugin packages really registered?"""
    problems = 0
    step("Card plugins")
    checker = host_repo() / "scripts" / "check_plugin_entrypoints.py"
    plugins = [p for p, _ in pkgs if p.startswith("wdnapps")]
    if not plugins:
        warn("no plugin packages are listed in packages.conf")
        return 0
    if not checker.is_file():
        warn(f"the checker script is missing: {checker}")
        return 0

    for pkg in plugins:
        try:
            r = subprocess.run(
                [sys.executable, str(checker), pkg],
                cwd=str(host_repo()), capture_output=True, text=True,
                timeout=120, stdin=subprocess.DEVNULL,
            )
        except Exception as e:
            warn(f"{pkg}: the check could not be run: {e}")
            problems += 1
            continue
        cards = 0
        bads = []
        for line in (r.stdout or "").splitlines():
            line = line.strip()
            if line.startswith("OK "):
                cards += 1
            elif line.startswith("BAD"):
                bads.append(line)
        if bads:
            bad(f"{pkg}: {len(bads)} card(s) failed the registration check")
            for b in bads:
                note(f"  {b}")
            problems += 1
        else:
            ok(f"{pkg}: {cards} card(s) registered")
    return problems


def _check_repos(online: bool = False) -> int:
    """The state of the repos — and with --online whether they are behind
    their remote.

    Only the two repos that **wdn itself pulls** are compared with the
    source site: wardner and the host application. The 8 SDK packages
    are updated by ``update_rkwhl.sh``, which manages their remotes on
    its own — their tracked remote may legitimately be the Gitee mirror
    (a read-only mirror is a valid source, see ``READONLY_HOSTS``), so
    comparing it with the source site produces nothing but noise.
    """
    problems = 0
    step("Repos")
    wrepo = wardner_repo()
    hrepo = host_repo()
    pkgs = read_packages_conf(wrepo)
    host_name = os.environ.get("WARDNER_HOST_REPO") or "wdnwebui"
    source_host = resolve_source_host()
    managed = {repo_name_of(wrepo, wrepo.name), host_name}

    for name, path, _ in _all_repos(wrepo, hrepo, pkgs, host_name):
        if not (path / ".git").is_dir():
            warn(f"{name}: not installed")
            continue
        br = current_branch(path)
        tr = tracked_remote(path, br)
        url = ""
        for rname, rurl in list_remotes(path):
            if rname == tr:
                url = rurl
                break
        sha = short(rev(path))
        h = host_of(url)
        if not url:
            warn(f"{name}: {sha} — no remote is tracked")
            continue
        if name in managed and h != source_host:
            warn(f"{name}: {sha} — the tracked remote points at {h or 'an unknown host'},"
                 f" not at the source site {source_host}")
        else:
            ok(f"{name}: {sha} — {br} → {h}")

        if online and url:
            r = _git(["ls-remote", url, br], path, timeout=60)
            if r.returncode == 0 and r.stdout.strip():
                remote_sha = r.stdout.split()[0]
                if remote_sha and remote_sha != rev(path):
                    bad(f"{name}: behind the remote — local {short(rev(path))},"
                        f" remote {short(remote_sha)}")
                    note("  run: wdn update")
                    problems += 1
                else:
                    ok(f"{name}: up to date with {h}")

    note(f"the source site is {source_host} — only {' / '.join(sorted(managed))} are compared "
         "against it;")
    note("the SDK packages are pulled by update_rkwhl.sh, their remote may be the Gitee mirror")
    return problems


def cmd_doctor(args: argparse.Namespace) -> int:
    """Check the system environment and the installation."""
    pkgs = read_packages_conf(wardner_repo())

    problems = 0
    problems += _check_system()
    problems += _check_wdn_on_path()
    problems += _check_toolchain()
    problems += _check_native_libs(pkgs)
    problems += _check_hardware_libs(pkgs)
    problems += _check_hardware_capabilities()
    problems += _check_hardware_nodes()
    problems += _check_sdk_imports()
    problems += _check_sdk_versions(pkgs)
    problems += _check_requirement_versions()
    problems += _check_declared_deps()
    problems += _check_plugins(pkgs)
    problems += _check_repos(online=getattr(args, "online", False))

    step("Summary")
    if problems == 0:
        ok("everything checks out")
        return 0
    bad(f"{problems} problem(s) found — see the details above")
    return 1


# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wdn",
        description="the wardner command line tool: update / inspect the wdnwebui installation on this board.",
    )
    p.add_argument("--version", action="version", version=f"wdn {VERSION}")
    sub = p.add_subparsers(dest="cmd")

    up = sub.add_parser("update", help="update every downloaded repo to the latest revision of the source site (GitHub / the Gitee mirror) and re-sync the venv")
    up.add_argument("--dry-run", action="store_true", help="only show what would happen, do not pull / install")
    up.add_argument("--keep-remotes", action="store_true",
                    help="leave the remotes and the branch tracking of every repo alone (by default they are aligned to the source site)")
    up.set_defaults(func=cmd_update)

    st = sub.add_parser("status", help="list the commit / remote of every repo and the state of the venv")
    st.set_defaults(func=cmd_status)

    dr = sub.add_parser("doctor", help="check the system environment: the native .so files, the system libraries of the hardware engines (MPP / RGA / Mali / RKNN), the SDK versions, the dependency versions, the plugin registration")
    dr.add_argument("--online", action="store_true",
                    help="also compare the local HEAD with the tip of the remote (needs the network)")
    dr.set_defaults(func=cmd_doctor)

    vn = sub.add_parser("version", help="print the version")
    vn.set_defaults(func=cmd_version)

    stt = sub.add_parser(
        "start",
        help="start the wdnwebui service in the background and listen on the given port",
    )
    stt.add_argument("port", nargs="?", type=int, default=DEFAULT_PORT,
                     help=f"the TCP port to listen on (default: {DEFAULT_PORT})")
    stt.add_argument("--timeout", type=float, default=60.0,
                     help="how long to wait for the service to answer on /health "
                          "(default: 60s)")
    stt.set_defaults(func=cmd_start)

    spt = sub.add_parser("stop", help="stop the wdnwebui service")
    spt.set_defaults(func=cmd_stop)

    return p


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        args = parser.parse_args(["--help"])
        return 0
    try:
        return args.func(args)
    except KeyboardInterrupt:
        err("\n[fail] interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
