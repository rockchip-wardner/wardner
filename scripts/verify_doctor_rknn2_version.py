#!/usr/bin/env python3
"""验证 `wdn doctor` 的 rknn2 runtime 版本检查。

背景：rknn2 runtime 2.3.2 的 normalize 算子只支持 NHWC 源布局，而 cshim 按
模型声明的布局喂输入 ⇒ runtime 内部报错、但 ``rknn_inputs_set`` 仍返回 0
⇒ VAE 解码「成功」地输出一张废图（整张棕黄色纹理）。

⇒ 「文件在不在」查不出这个问题，**必须查版本**。doctor 现在会：

  * 在 ``librknnrt.so`` 那一行把 runtime 自己的版本打出来；
  * 版本低于 2.5.0 时给一条**说清后果**的警告（不计入 problem 数 ——
    库在、服务能起、别的功能也能用，只有这一个功能静默出错）。

本脚本不碰 NPU、不 dlopen（doctor 也不 dlopen —— dlopen 会初始化 NPU 驱动，
健康检查不能去动活会话的硬件），只测纯逻辑 + 文件读取。

用法: python3 scripts/verify_doctor_rknn2_version.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CLI = REPO / "cli" / "wdn.py"

FAILED: list[str] = []
PASSED = 0


def check(cond: bool, what: str) -> None:
    global PASSED
    if cond:
        PASSED += 1
        print(f"  ok   {what}")
    else:
        FAILED.append(what)
        print(f"  FAIL {what}")


def load_cli():
    # 导入 CLI 会写 cli/__pycache__/*.pyc —— 这个仓把一个 .pyc 纳入了版本
    # 管理，别让本脚本再添一个。
    saved = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location("wdn_cli", CLI)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        sys.dont_write_bytecode = saved
    return mod


def make_lib(path: Path, banner: str) -> None:
    """A file that looks like a native library with a version banner in it."""
    with open(path, "wb") as f:
        f.write(b"\x7fELF" + b"\x00" * 64)
        f.write(b"\x00" * 32)
        f.write(banner.encode())
        f.write(b"\x00" * 32)


def main() -> int:
    if not CLI.is_file():
        print(f"FAIL: {CLI} not found")
        return 1
    m = load_cli()

    print("[1] 版本下限表")
    entry = m.SYSTEM_LIB_MIN_VERSION.get("librknnrt.so")
    check(entry is not None, "librknnrt.so has a minimum-version entry")
    if entry:
        banner, minimum, why = entry
        check(minimum == "2.5.0", f"the minimum is 2.5.0 (got {minimum})")
        check("librknnrt version:" in banner,
              f"the banner prefix matches the runtime's own string (got {banner!r})")
        check("VAE" in why and "废图" in why,
              "the warning says what actually breaks (VAE decode)")

    print("\n[2] 版本号比较")
    check(m._version_tuple("2.3.2") < m._version_tuple("2.5.0"),
          "2.3.2 < 2.5.0")
    check(m._version_tuple("2.5.0") == m._version_tuple("2.5.0"),
          "2.5.0 == 2.5.0")
    check(m._version_tuple("2.5.1") > m._version_tuple("2.5.0"),
          "2.5.1 > 2.5.0")
    check(m._version_tuple("2.10.0") > m._version_tuple("2.5.0"),
          "2.10.0 > 2.5.0  (numeric, not string compare)")
    check(m._version_tuple("2.5") < m._version_tuple("2.5.0"),
          "2.5 < 2.5.0")

    print("\n[3] 从文件里读版本（不 dlopen）")
    with tempfile.TemporaryDirectory() as td:
        old = Path(td) / "librknnrt.so"
        make_lib(old, "librknnrt version: 2.3.2 (429f97ae6b@2025-04-09T09:09:27)")
        new = Path(td) / "librknnrt.so.2.5.0"
        make_lib(new, "librknnrt version: 2.5.0 (74ea630ce8@2026-09-30T09:41:17)")
        blank = Path(td) / "blank.so"
        blank.write_bytes(b"\x7fELF" + b"\x00" * 256)

        check(m._lib_banner_version(old, "librknnrt version:") == "2.3.2",
              "an old library reports 2.3.2")
        check(m._lib_banner_version(new, "librknnrt version:") == "2.5.0",
              "a new library reports 2.5.0")
        check(m._lib_banner_version(blank, "librknnrt version:") == "",
              "a library without the banner reports nothing")
        check(m._lib_banner_version(Path(td) / "missing.so",
                                    "librknnrt version:") == "",
              "a missing file reports nothing (no exception)")

        print("\n[4] doctor 的那一行：版本过低 → 警告 + 说清后果")
        buf = io.StringIO()
        real_find = m._find_system_lib
        real_apt = m._apt_versions
        real_unresolved = m._unresolved_deps
        # 其它库都给一个「在、但没有 banner」的文件 ⇒ 它们不会把 problem
        # 计数弄脏（只有 librknnrt.so 这条是我们要验的）。
        other = Path(td) / "other.so"
        make_lib(other, "some other library 1.0")
        m._find_system_lib = lambda soname: old if soname == "librknnrt.so" else other
        m._apt_versions = lambda pkgs: {}
        m._unresolved_deps = lambda p: []
        try:
            with contextlib.redirect_stdout(buf):
                problems = m._check_hardware_libs([("wdnai", "wdnai")])
        finally:
            m._find_system_lib = real_find
            m._apt_versions = real_apt
            m._unresolved_deps = real_unresolved
        out = buf.getvalue()
        print("\n".join("      | " + ln for ln in out.splitlines()
                        if "rknnrt" in ln or "runtime" in ln))
        check("runtime 2.3.2" in out,
              "the line shows the runtime's own version")
        check("2.5.0 or newer is required" in out,
              "the warning names the required version")
        check("normalize error(-1)" in out,
              "the warning quotes the log line the user can look for")
        check("rknn2-runtime_2.5.0-1_arm64.deb" in out,
              "the warning says how to fix it")
        check(problems == 0,
              f"an old runtime is a warning, not a problem (problems={problems})")

    print("\n[5] 版本读不到 → 也要说，别装作没事")
    with tempfile.TemporaryDirectory() as td:
        blank = Path(td) / "librknnrt.so"
        blank.write_bytes(b"\x7fELF" + b"\x00" * 256)
        other = Path(td) / "other.so"
        make_lib(other, "some other library 1.0")
        buf = io.StringIO()
        real_find = m._find_system_lib
        real_apt = m._apt_versions
        real_unresolved = m._unresolved_deps
        m._find_system_lib = lambda soname: blank if soname == "librknnrt.so" else other
        m._apt_versions = lambda pkgs: {"rknn2-runtime": "2.5.0-1"}
        m._unresolved_deps = lambda p: []
        try:
            with contextlib.redirect_stdout(buf):
                m._check_hardware_libs([("wdnai", "wdnai")])
        finally:
            m._find_system_lib = real_find
            m._apt_versions = real_apt
            m._unresolved_deps = real_unresolved
        out = buf.getvalue()
        check("could not be read" in out,
              "an unreadable version is reported, not silently accepted")

    print("\n[6] 板上的真实库（装了的话）")
    real = None
    for d in ("/usr/lib/aarch64-linux-gnu", "/usr/lib", "/lib/aarch64-linux-gnu"):
        p = Path(d) / "librknnrt.so"
        if p.is_file():
            real = p
            break
    if real is None:
        print("  skip no librknnrt.so on this board")
    else:
        v = m._lib_banner_version(real, "librknnrt version:")
        check(v != "", f"the board's librknnrt.so reports a version ({v})")
        if v:
            ok_min = m._version_tuple(v) >= m._version_tuple("2.5.0")
            print(f"      the board runs {v} "
                  f"({'ok' if ok_min else 'TOO OLD — the VAE would produce garbage'})")
            if not ok_min:
                print("      (this is a finding, not a script failure — the "
                      "doctor will warn about it)")

    print(f"\n--- {PASSED} passed, {len(FAILED)} failed ---")
    for f in FAILED:
        print("  FAIL", f)
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
