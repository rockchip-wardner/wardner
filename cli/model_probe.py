#!/usr/bin/env python3
"""Probe the wdnai model catalog and the model files that are on disk.

Run it with the **venv python** (the interpreter that has wdnai installed):

    python cli/model_probe.py            # human readable
    python cli/model_probe.py --json     # one JSON object on stdout

Why a separate program
----------------------
``cli/wdn.py`` only depends on the standard library — the SDKs are never
imported *into* the CLI, they are probed in a child process (the same
pattern the SDK import smoke test uses). The point of this probe is exactly
that: **ask the installed wdnai where it expects its files**, instead of
guessing from a hard-coded table.

What it reports
---------------
  * the **legal catalog** — the models the installed ``wdnai`` knows, i.e.
    the ``SystemLanguageModel`` factories that bind to a fixed model
    directory (``qwen3_vl_4b``, ``qwen3_5_vl_4b``, ``qwen3_tts`` …);
  * for every entry: the directory the SDK resolves, whether it exists and
    whether the required files are all there;
  * what actually lies in the models root — the worker manifests
    (``<dir>/<id>.json``, recognized by their ``spec_factory`` key) and the
    directories that no manifest claims.

The models root
---------------
``WDNAI_MODELS_DIR`` wins; the SDK default is ``/userdata/models``. The
wdnwebui service writes ``base.model_path`` into that variable at boot, so
the caller (``wdn status``) resolves the root the same way and passes it in.
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import sys
from pathlib import Path

#: The SDK default — the root every model directory hangs off when
#: ``WDNAI_MODELS_DIR`` is not set (see ``wdnai.model._models_root``).
DEFAULT_ROOT = "/userdata/models"

#: The legal catalog: ``(id, factory, dir name under the root, dir env var)``.
#:
#: ``factory`` is a :class:`wdnai.SystemLanguageModel` classmethod. Calling it
#: is the authoritative check: the SDK resolves the paths itself (env override
#: → ``$WDNAI_MODELS_DIR/<dir name>``) and raises :class:`FileNotFoundError`
#: listing the missing files.
#:
#: The ids are the model ids the worker manifests use (``<id>.json`` inside
#: the model folder) — the same ids the compute page shows.
CATALOG: tuple[tuple[str, str, str, str], ...] = (
    ("qwen3-vl-4b",            "qwen3_vl_4b",        "Qwen3-VL-4B",           "WDNAI_QWEN3_VL_4B_DIR"),
    ("qwen3.5-vl-4b",         "qwen3_5_vl_4b",      "Qwen3.5-4B",            "WDNAI_QWEN3_5_4B_VL_DIR"),
    ("qwen3.5-vl-9b",         "qwen3_5_vl_9b",      "Qwen3.5-VL-9B",         "WDNAI_QWEN3_5_VL_9B_DIR"),
    ("qwen3-4b",              "qwen3_4b",           "Qwen3-4B",              "WDNAI_QWEN3_4B_DIR"),
    ("qwen3-vl-embedding-2b", "qwen3_vl_embedding", "Qwen3-VL-Embedding-2B", "WDNAI_QWEN3_VL_EMBEDDING_2B_DIR"),
    ("qwen2.5-omni-3b",       "qwen_2_5_omni_3b",   "Qwen2.5-Omni-3B",       "WDNAI_QWEN_2_5_OMNI_3B_DIR"),
    ("locate-anything",       "locate_anything",    "LocateAnything-3B",     "WDNAI_LOCATE_ANYTHING_DIR"),
    ("depth-anything-v3",     "depth_anything_v3",  "Depth-Anything-V3",     "WDNAI_DEPTH_ANYTHING_V3_DIR"),
    ("qwen3-tts",             "qwen3_tts",          "Qwen3-TTS",             "WDNAI_QWEN3_TTS_DIR"),
    ("qwen3-asr",             "qwen3_asr",          "Qwen3-ASR",             "WDNAI_QWEN3_ASR_DIR"),
    ("qwen-image-2.1",        "qwen_image_21_512",  "Qwen-Image-2.1",        "WDNAI_QWEN_IMAGE_21_DIR"),
)

#: Models whose factory does **not** verify the files itself — the TTS and
#: ASR backends resolve them at load time. The file names come from the
#: backends (``wdnai/backends/tts.py`` / ``wdnai/backends/asr.py``).
BACKEND_REQUIRED: dict[str, tuple[str, ...]] = {
    "qwen3_tts": (
        "text_projection.1828.rknn", "text_projection.weight",
        "talker.1828.rknn", "talker.weight",
        "code_predictor.1828.rknn", "code_predictor.weight",
        "speech_decoder.1828.rknn", "speech_decoder.weight",
    ),
    "qwen3_asr": (
        "encoder_online.1828.rknn", "encoder_online.weight",
        "llm.1828.rknn", "llm.weight",
        "llm.embed.bin", "llm.tokenizer.gguf",
        "mel_128_filters.txt",
    ),
}

#: A manifest is a small json inside the model folder that carries a
#: ``spec_factory`` key (same rule as the wdnwebui worker discovery).
MANIFEST_MAX_BYTES = 64 * 1024

#: ``files missing under <dir>: ['a', 'b']`` — the message every
#: ``wdnai.model._verify_*_files()`` raises.
_MISSING_RE = re.compile(r"missing under (?P<dir>.+?): \[(?P<files>.*?)\]", re.S)


@contextlib.contextmanager
def _quiet_stdout():
    """Redirect stdout to stderr for the duration of the block.

    The native RKNN libraries print a banner (``rga_api version …``) when
    wdnai is imported. On stdout that would corrupt the JSON report, so the
    banner goes to stderr instead.
    """
    saved = sys.stdout
    sys.stdout = sys.stderr
    try:
        yield
    finally:
        sys.stdout = saved


def _import_wdnai():
    """Import the SDK, keeping its import banner off stdout."""
    with _quiet_stdout():
        import wdnai
        from wdnai import SystemLanguageModel
    return wdnai, SystemLanguageModel


def models_root() -> Path:
    """The root every model directory hangs off."""
    env = os.environ.get("WDNAI_MODELS_DIR", "").strip()
    return Path(env) if env else Path(DEFAULT_ROOT)


def _parse_missing(message: str) -> tuple[str, list[str]]:
    """Pull the directory and the missing file names out of a verify message.

    Returns ``("", [])`` when the message does not have the expected shape.
    """
    m = _MISSING_RE.search(message)
    if not m:
        return "", []
    # The list is a Python repr — but one element may be a free-form string
    # ("[DiT] a, b"), so the quoted names are extracted one by one instead of
    # evaluating the repr.
    files = re.findall(r"'([^']*)'", m.group("files"))
    return m.group("dir").strip(), files


def _spec_dir(spec) -> str:
    """The model directory a built :class:`wdnai.ModelSpec` points at."""
    for field in ("tts_model_dir", "omni_model_dir", "asr_model_dir", "image_model_dir"):
        value = getattr(spec, field, "") or ""
        if value:
            return str(value)
    for field in ("rknn_llm_path", "rknn_path", "rknn_vision_path", "depth_local_path"):
        value = getattr(spec, field, "") or ""
        if value:
            return str(Path(value).parent)
    return ""


def probe_model(mid: str, factory_name: str, dir_name: str, env_var: str,
                root: Path, system_language_model) -> dict:
    """Probe one catalog entry against the installed wdnai."""
    entry = {
        "id": mid,
        "factory": factory_name,
        "dir_name": dir_name,
        "env": env_var,
        "dir": "",
        "exists": False,
        "complete": None,     # None = the SDK does not verify this model itself
        "missing": [],
        "error": "",
        "known": False,
    }

    factory = getattr(system_language_model, factory_name, None)
    if factory is None:
        entry["error"] = "this wdnai version has no such model"
        return entry
    entry["known"] = True

    override = os.environ.get(env_var, "").strip()
    entry["dir"] = str(Path(override) if override else root / dir_name)

    try:
        spec = factory()
    except FileNotFoundError as exc:
        missing_dir, missing = _parse_missing(str(exc))
        entry["complete"] = False
        entry["missing"] = missing
        if missing_dir:
            entry["dir"] = missing_dir
        entry["exists"] = Path(entry["dir"]).is_dir()
        return entry
    except Exception as exc:  # noqa: BLE001 - a broken model must not kill the report
        entry["error"] = f"{type(exc).__name__}: {exc}"
        entry["exists"] = Path(entry["dir"]).is_dir()
        return entry

    resolved = _spec_dir(spec)
    if resolved:
        entry["dir"] = resolved
    entry["exists"] = Path(entry["dir"]).is_dir()

    required = BACKEND_REQUIRED.get(factory_name)
    if required:
        missing = [f for f in required if not (Path(entry["dir"]) / f).is_file()]
        entry["complete"] = not missing
        entry["missing"] = missing
    else:
        entry["complete"] = True
    return entry


def find_manifests(model_dir: Path) -> list[dict]:
    """The worker manifests inside one model folder.

    A json file is a manifest when it carries a ``spec_factory`` key — a
    model folder may hold other json files (tokenizer configs and friends).
    """
    out: list[dict] = []
    try:
        candidates = sorted(model_dir.glob("*.json"))
    except OSError:
        return out
    for path in candidates:
        if path.name.startswith((".", "_")):
            continue
        try:
            if path.stat().st_size > MANIFEST_MAX_BYTES:
                continue
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(raw, dict) or "spec_factory" not in raw:
            continue
        out.append({
            "file": path.name,
            "id": str(raw.get("id") or path.stem),
            "label": str(raw.get("label") or path.stem),
            "spec_factory": str(raw.get("spec_factory") or ""),
            "model_dir_name": str(raw.get("model_dir_name") or ""),
            "model_dir_env": str(raw.get("model_dir_env") or ""),
        })
    return out


def probe_root(root: Path, factories: set[str]) -> dict:
    """What actually lies in the models root."""
    installed: list[dict] = []
    unknown_dirs: list[str] = []
    known_dir_names = {entry[2] for entry in CATALOG}

    if not root.is_dir():
        return {"installed": installed, "unknown_dirs": unknown_dirs}

    try:
        dirs = sorted(p for p in root.iterdir() if p.is_dir())
    except OSError:
        return {"installed": installed, "unknown_dirs": unknown_dirs}

    for model_dir in dirs:
        if model_dir.name.startswith((".", "_")):
            continue
        manifests = find_manifests(model_dir)
        if not manifests:
            if model_dir.name not in known_dir_names:
                unknown_dirs.append(model_dir.name)
            continue
        for manifest in manifests:
            manifest["dir"] = model_dir.name
            manifest["known_factory"] = manifest["spec_factory"] in factories
            installed.append(manifest)
    return {"installed": installed, "unknown_dirs": unknown_dirs}


def build_report() -> dict:
    """The whole report — the JSON the CLI renders."""
    root = models_root()

    import_error = ""
    try:
        wdnai, system_language_model = _import_wdnai()
        sdk_version = getattr(wdnai, "__version__", "") or ""
    except Exception as exc:  # noqa: BLE001 - reported in the JSON, never raised
        sdk_version = ""
        system_language_model = None
        import_error = f"import wdnai failed: {exc}"

    if system_language_model is None:
        models = []
        for mid, factory_name, dir_name, env_var in CATALOG:
            models.append({
                "id": mid, "factory": factory_name, "dir_name": dir_name,
                "env": env_var, "dir": "", "exists": False, "complete": None,
                "missing": [], "known": False,
                "error": import_error,
            })
    else:
        models = [probe_model(*entry, root, system_language_model) for entry in CATALOG]

    factories = {m["factory"] for m in models if m["known"]}
    root_state = probe_root(root, factories)

    return {
        "root": str(root),
        "root_exists": root.is_dir(),
        "sdk_version": sdk_version,
        "models": models,
        "installed": root_state["installed"],
        "unknown_dirs": root_state["unknown_dirs"],
    }


def render(report: dict) -> str:
    """A human readable rendering (used when --json is not given)."""
    lines: list[str] = []
    lines.append(f"models root   {report['root']}"
                 + ("" if report["root_exists"] else "   (does not exist)"))
    for model in report["models"]:
        if not model["known"]:
            state = "not in this wdnai"
        elif not model["exists"]:
            state = "directory missing"
        elif model["complete"] is False:
            state = "files missing: " + ", ".join(model["missing"])
        else:
            state = "ok"
        lines.append(f"  {model['id']:<24} {model['dir_name']:<22} {state}")
    for manifest in report["installed"]:
        flag = "" if manifest["known_factory"] else "   (unknown spec_factory)"
        lines.append(f"  [manifest] {manifest['id']:<21} {manifest['label']}{flag}")
    return "\n".join(lines)


def _write_json(payload: str) -> None:
    """Write the JSON report to stdout, keeping the native banner away.

    The RKNN libraries print a version banner when the process tears down
    (i.e. *after* ``main()`` returned) — on stdout that would corrupt the
    report. So the real stdout is duplicated first, fd 1 is pointed at
    stderr, and the report is written to the duplicate.
    """
    saved = os.dup(1)
    os.dup2(2, 1)
    try:
        os.write(saved, (payload + "\n").encode("utf-8"))
    finally:
        os.close(saved)


def main(argv: list[str]) -> int:
    report = build_report()
    if "--json" in argv:
        _write_json(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
