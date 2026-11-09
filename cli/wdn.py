#!/usr/bin/env python3
"""wdn —— wardner 命令行工具。

子命令
------
  update    把所有已下载的仓库更新到 GitHub 上的最新版本，并重新同步 venv
  status    列出各仓的本地 commit、remote 和 venv 的就绪状态
  version   打印版本号

用 **venv 的 python** 跑（见 bin/wdn）
----------------------------------------
CLI 本身只依赖标准库，但它跑在 `~/.wardner/wdnwebui/.venv/bin/python` 下，
有两个好处：

  * 能直接 import SDK（wdnai / wdnav / …），做「装完到底能不能用」的判断；
  * 更新完可以在同一个解释器里做冒烟验证 —— 更新前后的环境是同一套。

「拉代码」和「装包」为什么必须分开
--------------------------------
拉代码改的是源码树，装包改的是 .venv。editable 安装意味着纯 Python 包
拉完即生效，但带 build hook 的包（wdndds / wdnav）**必须重装**才会重新编
.so —— 只 pull 不重装，源码是新的、.so 还是旧的。

8 个 SDK 包的「pull + 判断要不要重装」交给宿主仓里的 `update_rkwhl.sh`，
它靠 **pull 前后的 HEAD 对比**决定要不要重装。⚠️ 顺序不能颠倒：

    先让 update_rkwhl.sh 自己 pull  →  它看到 HEAD 变了 → 重装 + 重编 .so
    如果 wdn 先 pull                →  它看到 HEAD 没变 → 跳过重装 → .so 不重编

所以 wdn 只负责它自己的两个仓（wardner / wdnwebui），SDK 包交给
update_rkwhl.sh —— 不重复实现那套 HEAD 对比逻辑。
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# 输出
#
# 板端没有 emoji / 符号字体：🖼 ✕ ⚠ ✓ ☑ ▯ 🗑 📁 全渲染成豆腐块（□）。
# 板端可用的只有 `× ● ■ ▶ ← → ↑ ↓` —— 下面只用这些。
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
# 路径
# ---------------------------------------------------------------------------

def wardner_home() -> Path:
    """安装根目录（~/.wardner）。"""
    env = os.environ.get("WARDNER_HOME")
    if env:
        return Path(env).expanduser().resolve()
    # cli/wdn.py → <wardner>/cli → <wardner> → <wardner_home>
    return Path(__file__).resolve().parent.parent.parent


def wardner_repo() -> Path:
    """本仓（安装器自身）所在目录。"""
    return Path(__file__).resolve().parent.parent


def host_repo() -> Path:
    """宿主应用仓。"""
    env = os.environ.get("WARDNER_HOST_REPO") or "wdnwebui"
    return wardner_home() / env


def venv_dir() -> Path:
    return host_repo() / ".venv"


def venv_python() -> Path:
    return venv_dir() / "bin" / "python"


def venv_src() -> Path:
    return venv_dir() / "src"


# ---------------------------------------------------------------------------
# git
#
# GIT_TERMINAL_PROMPT=0：remote 不对时 git 会要用户名/密码，那样会**卡住**
#   等输入。宁可立刻失败，也好过挂死。
# lowSpeedLimit/lowSpeedTime：git 默认没有连接超时，TCP 层失败要等 135s 才报
#   （实测 "Failed to connect ... after 135137 ms"）。压到 30s。
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
        return subprocess.CompletedProcess(args, 124, "", f"超时（>{timeout}s）")


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
    """[(remote 名, URL)]。remote 名不统一（origin / github / rk 都见过）。"""
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
    """当前分支跟踪的 remote 名（branch.<br>.remote）。"""
    if not branch:
        return ""
    return git_out(["config", "--get", f"branch.{branch}.remote"], repo)


def norm_remote(url: str) -> str:
    """把 remote URL 归一化成可比较的形式。

    下列写法归一化后应当相等：
        git@github.com:org/repo.git
        ssh://git@github.com/org/repo.git
        https://github.com/org/repo.git
    """
    u = (url or "").strip()
    if u.startswith("git+"):
        u = u[4:]
    if u.endswith(".git"):
        u = u[:-4]
    u = u.replace("git@github.com:", "github.com/")
    u = u.replace("ssh://git@github.com/", "github.com/")
    u = u.replace("https://github.com/", "github.com/")
    return u.rstrip("/")


def github_org_of(url: str) -> str:
    """从 remote URL 反推 GitHub 组织名，取不到返回空串。"""
    parts = norm_remote(url).split("/")
    if len(parts) >= 3 and parts[0] == "github.com":
        return parts[1]
    return ""


def resolve_org() -> str:
    """本次操作使用的 GitHub 组织。

    优先环境变量，其次本仓 remote 里写着的（remote 是事实，推断归推断）。
    """
    env = os.environ.get("WARDNER_ORG")
    if env:
        return env
    return github_org_of(remote_of(wardner_repo())) or "rockchip-wardner"


def pull(repo: Path, dry_run: bool = False, retries: int = 5, delay: int = 5):
    """git pull --ff-only。返回 (before, after, ok, message)。"""
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
            warn(f"git pull 失败（第 {attempt}/{retries} 次）：{last}")
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
        bad(f"clone 失败：{url}")
        if blob:
            for line in blob.splitlines()[-3:]:
                note(line)
        return False
    return True


# ---------------------------------------------------------------------------
# 包清单
# ---------------------------------------------------------------------------

def read_packages_conf(repo: Path) -> list[tuple[str, str]]:
    """读 packages.conf → [(目录名, GitHub 仓名)]。"""
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


def repo_name_of(repo: Path, fallback: str) -> str:
    """从 remote URL 反推仓名。"""
    parts = norm_remote(remote_of(repo)).split("/")
    if len(parts) >= 3 and parts[0] == "github.com":
        return parts[-1]
    return fallback


def _sync_remotes(name: str, repo: Path, want_url: str, keep: bool = False,
                  dry_run: bool = False) -> None:
    """把仓的 remote 对齐到 GitHub，并保证 pull 真的从 GitHub 走。

    ⚠️ remote 名不统一（origin / github / rk 都见过），而 `git pull` 不带
       参数时用的是 ``branch.<br>.remote`` —— **只改 origin 的 URL 是不生效
       的**：这台板子上 8 个包的 master 跟踪的是 `github`（已指向 GitHub），
       而 `origin` 指着内网镜像；反过来也有仓跟踪的是内网那个。

    规则：

    * 所有 remote 的 URL 都指向 GitHub（内网镜像 → GitHub）；
    * **只在**当前分支跟踪的 remote 不指向 GitHub 时，才把跟踪关系改到
      一个指向 GitHub 的 remote —— 跟踪关系同时也是用户的推送路径，擅自
      改会让 `git push` 悄悄改道。
    """
    want_key = norm_remote(want_url)

    # ① URL 对齐
    for rname, url in list_remotes(repo):
        if norm_remote(url) == want_key or keep:
            continue
        if dry_run:
            note(f"[dry-run] {name}: {rname} {url or '(空)'} → {want_url}")
            continue
        if _git(["remote", "set-url", rname, want_url], repo).returncode == 0:
            ok(f"{name}: {rname} {url or '(空)'} → {want_url}")

    # ② 分支跟踪
    br = current_branch(repo)
    if keep or not br or br == "HEAD":
        return

    remotes = list_remotes(repo)   # 改完 URL 重新读一遍
    tracked = tracked_remote(repo, br)
    tracked_url = ""
    for rname, url in remotes:
        if rname == tracked:
            tracked_url = url
            break

    if tracked and norm_remote(tracked_url) == want_key:
        return   # 已经在 GitHub 上 —— 不动用户的跟踪关系

    # 挑一个指向 GitHub 的 remote：优先 HTTPS（匿名可用）
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
            note(f"[dry-run] {name}: 新建 remote origin → {want_url}")
        elif _git(["remote", "add", "origin", want_url], repo).returncode == 0:
            ok(f"{name}: 新建 remote origin → {want_url}")

    if dry_run:
        note(f"[dry-run] {name}: 分支 {br} 跟踪 {tracked or '(无)'} → {pick}")
        return
    _git(["config", f"branch.{br}.remote", pick], repo)
    if br == "master":
        _git(["config", f"branch.{br}.merge", "refs/heads/master"], repo)
    ok(f"{name}: 分支 {br} 跟踪 {tracked or '(无)'} → {pick}（GitHub）")


# ---------------------------------------------------------------------------
# 子命令：update
# ---------------------------------------------------------------------------

def cmd_update(args: argparse.Namespace) -> int:
    wrepo = wardner_repo()
    hrepo = host_repo()
    src = venv_src()
    vpy = venv_python()

    if not vpy.is_file():
        err(
            "[fail] 还没装好 —— 找不到 venv 的 python",
            f"       {vpy}",
            f"       先跑一遍安装： bash {wrepo}/install.sh",
        )
        return 2

    org = resolve_org()
    host_name = os.environ.get("WARDNER_HOST_REPO") or "wdnwebui"
    results: list[tuple[str, str, str, bool, str]] = []  # 名, before, after, ok, msg

    step("更新仓库")

    # ① 先更新自己 —— 后面的 packages.conf 才是最新的
    before, after, good, msg = pull(wrepo, args.dry_run)
    results.append((repo_name_of(wrepo, wrepo.name), before, after, good, msg))
    if not good:
        bad(f"{wrepo.name} 更新失败：{msg}")

    # ② 上游 packages.conf 加了新包的话，这里补 clone
    pkgs = read_packages_conf(wrepo)
    if pkgs:
        step("补齐缺失的包")
        for pkg, repo_name in pkgs:
            dest = src / pkg
            if (dest / ".git").is_dir():
                continue
            note(f"{pkg} 缺失 —— clone")
            if not clone(f"https://github.com/{org}/{repo_name}.git", dest, args.dry_run):
                bad(f"{pkg} 拉取失败")

    # ③ remote 对齐 GitHub
    #
    # 「wdn update 通过 GitHub 更新」是硬要求。仓的 remote 被指到内网镜像时，
    # 这里改回 GitHub；分支跟踪关系只在「跟踪的 remote 不指向 GitHub」时才
    # 动 —— 跟踪关系也是用户的推送路径，擅自改会让 `git push` 改道。
    step("对齐 remote 到 GitHub")
    for name, path, repo_name in _all_repos(wrepo, hrepo, pkgs, host_name):
        if not (path / ".git").is_dir():
            continue
        _sync_remotes(
            name, path, f"https://github.com/{org}/{repo_name}.git",
            keep=args.keep_remotes, dry_run=args.dry_run,
        )

    # ④ pull 宿主应用
    step("拉取最新代码")
    before, after, good, msg = pull(hrepo, args.dry_run)
    results.append((host_name, before, after, good, msg))
    if good:
        if before == after:
            ok(f"{host_name}: {short(after)} （无变化）")
        else:
            ok(f"{host_name}: {short(before)} → {short(after)}")
    else:
        bad(f"{host_name} 更新失败：{msg}")

    # ⑤ 8 个 SDK 包 —— 交给 update_rkwhl.sh
    #
    # 它自己 pull（所以 HEAD 前后对比才有意义），HEAD 变了就卸载重装 +
    # 重编 .so，并做 .so 落地断言 / 卡片注册校验 / 依赖审计。
    step("同步 SDK / 插件包")
    pkg_before = {pkg: rev(src / pkg) for pkg, _ in pkgs if (src / pkg / ".git").is_dir()}

    script = hrepo / "update_rkwhl.sh"
    if not script.is_file():
        bad(f"找不到 {script}")
        return 1
    if args.dry_run:
        note("[dry-run] 跳过 update_rkwhl.sh（它会真的 pip install）")
    else:
        env = {**os.environ, "WARDNER_PKG_BASE": f"git+https://github.com/{org}"}
        r = subprocess.run(
            ["bash", str(script)],
            cwd=str(hrepo),
            env=env,
            stdin=subprocess.DEVNULL,
        )
        if r.returncode != 0:
            bad(f"update_rkwhl.sh 未全部成功（exit {r.returncode}）—— 详见上方日志")

    for pkg, _ in pkgs:
        p = src / pkg
        if not (p / ".git").is_dir():
            continue
        b = pkg_before.get(pkg, "")
        a = rev(p)
        results.append((pkg, b, a, True, ""))

    # ⑥ 冒烟：4 个 SDK 必须真的 import 得起来
    if not args.dry_run:
        step("冒烟验证")
        _smoke()

    # ⑦ 汇总
    step("汇总")
    _print_results(results)

    if any(not good for _, _, _, good, _ in results):
        return 1
    return 0


def _all_repos(wrepo: Path, hrepo: Path, pkgs: list[tuple[str, str]], host_name: str):
    """(显示名, 路径, 期望的 GitHub 仓名)"""
    out = [
        (repo_name_of(wrepo, wrepo.name), wrepo, repo_name_of(wrepo, wrepo.name)),
        (host_name, hrepo, host_name),
    ]
    for pkg, repo_name in pkgs:
        out.append((pkg, venv_src() / pkg, repo_name))
    return out


def _smoke() -> None:
    """在 venv 的 python 里 import 4 个 SDK。

    这道断言必须有：update_rkwhl.sh 的 verify_outputs 对 wdnai / wdnhid
    直接 `return 0`（纯 Python，没有 .so 可断言），audit_sdk_deps 也只查
    「SDK 声明的依赖能不能用」，不查包自身能不能 import。editable 装歪
    （.pth 指向不存在的路径）会穿过所有门禁。
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
        bad("SDK import 检查未通过 —— 上面失败的包没装好")
        err(
            "[fail] SDK import 检查未通过",
            "       常见原因：editable 安装的 .pth 指向了不存在的路径。",
            "       修复：删掉对应包目录后重跑 wdn update：",
            f"         rm -rf {venv_src()}/<包名>",
        )


def _print_results(results) -> None:
    if not results:
        return
    width = max(len(name) for name, _, _, _, _ in results)
    for name, before, after, good, msg in results:
        if not good:
            print(f"  {name:<{width}}  {C_RED}{short(before)} → {short(after)}  失败{C_RST}")
            if msg:
                note(msg)
            continue
        if before and after and before != after:
            print(f"  {name:<{width}}  {short(before)} → {C_GRN}{short(after)}{C_RST}")
        else:
            print(f"  {name:<{width}}  {short(after)}")


# ---------------------------------------------------------------------------
# 子命令：status
# ---------------------------------------------------------------------------

def cmd_status(args: argparse.Namespace) -> int:
    wrepo = wardner_repo()
    hrepo = host_repo()
    org = resolve_org()
    pkgs = read_packages_conf(wrepo)

    step("仓库状态")
    rows = []
    for name, path, _ in _all_repos(wrepo, hrepo, pkgs, os.environ.get("WARDNER_HOST_REPO") or "wdnwebui"):
        if not (path / ".git").is_dir():
            rows.append((name, "—", "（未安装）"))
            continue
        br = current_branch(path)
        tr = tracked_remote(path, br)
        url = ""
        for rname, rurl in list_remotes(path):
            if rname == tr:
                url = rurl
                break
        rows.append((name, short(rev(path)), f"{tr or '-'} → {url or '（无 remote）'}"))

    width = max(len(r[0]) for r in rows)
    for name, sha, rem in rows:
        print(f"  {name:<{width}}  {sha}  {C_DIM}{rem}{C_RST}")

    step("venv")
    vpy = venv_python()
    if not vpy.is_file():
        bad(f"还没装好 —— {vpy} 不存在")
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
# 子命令：version
# ---------------------------------------------------------------------------

def cmd_version(args: argparse.Namespace) -> int:
    print(f"wdn {VERSION}")
    print(f"  安装根目录  {wardner_home()}")
    print(f"  安装器仓    {wardner_repo()}")
    print(f"  宿主应用    {host_repo()}")
    print(f"  venv python {venv_python()}")
    return 0


# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="wdn",
        description="wardner 命令行工具：更新 / 查看本板上的 wdnwebui 装置。",
    )
    p.add_argument("--version", action="version", version=f"wdn {VERSION}")
    sub = p.add_subparsers(dest="cmd")

    up = sub.add_parser("update", help="把所有已下载的仓更新到 GitHub 最新，并重新同步 venv")
    up.add_argument("--dry-run", action="store_true", help="只看会发生什么，不真的 pull / 装包")
    up.add_argument("--keep-remotes", action="store_true",
                    help="不动各仓的 remote 和分支跟踪（默认会对齐到 GitHub）")
    up.set_defaults(func=cmd_update)

    st = sub.add_parser("status", help="列出各仓的 commit / remote 和 venv 状态")
    st.set_defaults(func=cmd_status)

    vn = sub.add_parser("version", help="打印版本号")
    vn.set_defaults(func=cmd_version)

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
        err("\n[fail] 已中断")
        return 130


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
