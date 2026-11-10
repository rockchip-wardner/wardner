[English](README.md) | [简体中文](README_CN.md)
# wdnwebui One-Click Installer

One-click install scripts for the Rockchip platform web service
([wdnwebui](https://github.com/rockchip-wardner/wdnwebui)) and its SDKs / card
plugins.

---

## Two install sources

| Source | One-click command | When to use it |
|---|---|---|
| **GitHub** | `curl -fsSL https://github.com/rockchip-wardner/wardner/raw/master/install_github.sh \| bash` | Default; international networks |
| **Gitee domestic mirror** | `curl -fsSL https://gitee.com/rockchip-wardner/wardner/raw/master/install_gitee.sh \| bash` | Faster on domestic networks |

> ⚠️ The path is **`/raw/master/`**. Writing `.../wardner/install_github.sh` gives you a web
> page, not the raw file — curl will 404, or feed a chunk of HTML to bash.

### The source is declared by the entry script, not guessed

`install_github.sh` / `install_gitee.sh` are two **entry scripts**. Each declares the
source site it stands for (GitHub / Gitee) and then downloads the very same
`install.sh` and runs it — the actual install logic exists exactly once, the entry
scripts are thin shells.

> ⚠️ **Why `curl ... | bash` cannot guess the source on its own**: install.sh is only
> ~25KB, so it **fits into the pipe buffer in one go** — curl writes it and exits
> immediately, and by the time the script scans `/proc` for curl's command line, curl
> is long gone (measured: a 24KB script → no curl in `/proc`; 200KB → still there).
> So the old "scan `/proc` to infer the source" path **fails almost every time**: you
> install from Gitee, it quietly pulls from GitHub, and **nothing tells you**.
>
> The source now lives in the **file content**: the script name *is* the declaration,
> with no runtime guessing.

```
entry script ──▶ declared source ──▶ transport scheme ──▶ clone URL for 9 repos
```

* **GitHub / Gitee go over https** — public repos, an anonymous clone is enough: no
  account, no SSH key, so users who never logged in can install;
* **The intranet goes over ssh** — the intranet GitLab's web port is 8080 (that is the
  HTTP port); fetching the code over ssh is how an intranet should work (when you
  point `WARDNER_REPO_URL` at an intranet address yourself).

So **if you install from Gitee, the host app, the 8 SDK / plugin packages and every
later `wdn update` all go through Gitee**; if you install from GitHub, they all go
through GitHub. Nothing to configure.

> ⚠️ **Gitee is a read-only mirror — its content is synced from upstream automatically,
> do not push code to it.**
> Commits pushed there are overwritten by the next sync, with no warning at all. To
> push, use **GitHub** (or the intranet main repo).
>
> Under a Gitee source, `wdn update` points each repo's **pushurl back to GitHub** —
> fetching goes through the mirror (fast), pushing goes to GitHub (writable). It only
> sets that for you when you have not customized a pushurl yourself; if you have, it
> does not touch a single character.

One command installs the whole set into `~/.wardner`, creates the venv, installs the
dependencies and builds the native libraries.

---

## What you get after install

```
~/.wardner/
├── wardner/                    this repo (the installer itself)
│   ├── install.sh
│   ├── update.sh
│   ├── bin/wdn                 wdn command entry point (bash launcher)
│   └── cli/wdn.py              the real implementation of wdn (runs with .venv's python)
└── wdnwebui/                   host app (FastAPI service + card host)
    ├── app/  run.py  ...
    ├── requirements.txt
    └── .venv/                  virtual environment
        ├── bin/python
        └── src/                SDK / card plugin packages (each its own git repo)
            ├── wdnav/          MPP / RGA2 / V4L2 video
            ├── wdnai/          RKNN LLM / VLM / TTS
            ├── wdndds/         DDS / RPC (model isolation)
            ├── wdnhid/         USB Gadget HID
            ├── wdnapps_video_analyzer/
            ├── wdnapps_hdmi_processor/
            ├── wdnapps_audio_chat/
            └── wdnapps_media_generator/
```

Start it:

```bash
wdn start 8000                   # in the background → http://<board-ip>:8000/
```

Or in the foreground, to watch the logs:

```bash
cd ~/.wardner/wdnwebui
.venv/bin/python run.py
```

Update:

```bash
wdn update                     # recommended: update every repo + re-sync the venv
```

You can also use the script:

```bash
~/.wardner/wardner/update.sh
```

---

## What it actually does

| Step | What it does |
|---|---|
| Preflight checks | whether `git` / `python3` (≥ 3.9) / the `venv` module are all present |
| Fetch the host app | clone [wdnwebui](https://github.com/rockchip-wardner/wdnwebui) → `~/.wardner/wdnwebui` (**follows the source site**) |
| Create the venv | `~/.wardner/wdnwebui/.venv` |
| Fetch the packages | clone the 8 SDK / plugin repos → `.venv/src/<pkg>/` (**follows the source site**) |
| Build the dependencies | cmake / build-essential / patchelf / libfoonathan-memory-dev (if missing, it prints the install command) |
| Install and verify | delegated to the host repo's `update_rkwhl.sh` (see below) |
| Smoke test | `import wdnav/wdnai/wdndds/wdnhid` + assert that both `.so` files landed |
| Install wdn | put the command on PATH and write the environment into the rc files (`~/.bashrc` **and** `~/.zshrc`, see below) |

**Install and verification are not reimplemented here** — the installer calls
[`update_rkwhl.sh`](https://github.com/rockchip-wardner/wdnwebui/blob/master/update_rkwhl.sh)
in the host repo directly. Those 470 lines were honed on real boards, and they install
what it already knows how to install:

- install `requirements.txt` (the web-side dependencies)
- patch the PyPI `v4l2` package (a 2014 py2-era sdist) for py3 compatibility
- per package, `git pull` + reinstall editable (skipped when HEAD has not changed)
- **assert that the `.so` files of `wdndds` / `wdnav` really landed** — setuptools ≥64
  silently swallows a RuntimeError raised by the build hook, pip still returns 0, the
  screen is all green, but the artifacts were never produced
- **verify that the cards of the 4 plugin packages really registered** — the three-part
  chain entry point name ↔ manifest `"id"` ↔ `static/`; when they disagree pip reports
  success all the way through, while the host skips those cards as FATAL at startup
- **audit the dependencies each SDK declares for itself** — SDKs are installed with
  `--no-deps`, so their declared dependencies never enter the venv on their own, and
  the failure is far away from the cause (missing v4l2 → the HDMI-IN endpoint 503s;
  missing tokenizers → "模型启动失败" on the compute page)

---

## The `wdn` command

It exists right after the install — PATH is already written into the rc files of
the shells the user uses (`~/.bashrc` **and** `~/.zshrc`), the current user can
use it directly:

```bash
wdn update      # update every downloaded repo to the latest on the source site, and re-sync the venv
wdn status      # show each repo's commit / remote, the venv state and the models
wdn start 8080  # start the wdnwebui service in the background, listening on port 8080
wdn stop        # stop the wdnwebui service
wdn version     # version number
```

### `wdn start` / `wdn stop` — run the web service

```bash
wdn start 8080     # listen on 8080 (the port is optional — the default is 8000)
wdn stop           # stop it again
```

`wdn start` runs the service **in the background** — the command returns as soon as the
web UI answers on `/health`, and prints the URL to open:

```
▶ starting wdnwebui on port 8080
  ● wdnwebui started (pid 559670)
  ● the web UI is listening on http://192.168.169.215:8080/
```

| | |
|---|---|
| the pid file | `~/.wardner/run/wdnwebui.pid` |
| the log | `~/.wardner/logs/wdnwebui.log` |

The service runs in **its own session** — it survives the terminal it was started from,
and `wdn stop` signals the whole process group, so the uvicorn reloader *and* its
worker go down together. `wdn stop` waits until the port is really free before it
returns, so a `wdn stop` + `wdn start` cycle never hits `[Errno 98] Address already in use`.

No root and no systemd are needed — the pid file plus the process group behave the same
on every install. If the service is managed by **systemd** (the autostart unit of
`wdnwebui/install_autostart.sh`), `wdn stop` says so and points at `systemctl stop`
instead of fighting the service manager behind its back.

The `compute_worker` processes are spawned with their own session on purpose — they
survive the stop and are adopted again by the next boot (over DDS).

### `wdn status` — what is actually on the board

`wdn status` prints four blocks: the commit / remote of every repo, the venv, the SDK
imports and — because the model weights are the last thing that can be missing while
everything else looks healthy — the **models**:

```
▶ Models
  root  /mnt/oem/models  (wdnwebui config base.model_path)
  ● qwen3-vl-4b            Qwen3-VL-4B            ok          qwen3-vl-4b
  ● qwen3.5-vl-4b         Qwen3.5-4B             ok          qwen3.5-vl-4b
  ● qwen3-tts              Qwen3-TTS              ok          qwen3-tts
  × qwen3-asr              Qwen3-ASR              missing     -
  expected in /mnt/oem/models/Qwen3-ASR
  ...
  7 of 11 legal models are installed and complete
```

The catalog is **not** hard-coded in the CLI: the probe (`cli/model_probe.py`) asks the
installed `wdnai` for it — the `SystemLanguageModel` factories that bind to a fixed
model directory — and calls each factory, so both the paths and the "files missing"
verdict come from the SDK itself. The root is resolved the way the service resolves it:
`WDNAI_MODELS_DIR` first (the service writes `base.model_path` into it at boot), then
the `base.model_path` of the host config, then the SDK default `/userdata/models`.

The last column is the id of the worker manifest found in the model folder — that is the
id the compute page serves the model under. A manifest whose `spec_factory` is unknown
to the installed `wdnai` is reported as broken, and a folder in the model root that no
model claims is listed at the end.

### `wdn update` does three things

1. **Align the remotes with the source site.** A repo's remote may point elsewhere (an
   intranet mirror / another site); point it back at the **source site** — which source
   site that is, is decided by this repo's own remote: wherever you installed from is
   where you keep going. The branch tracking relationship is only touched when "the
   currently tracked remote does not point at the source site" — that relationship is
   also your push path, and changing it behind your back silently reroutes `git push`.
   To leave the remotes completely alone, add `--keep-remotes`.
   A remote named **`github`** is left alone — it is the push-only publishing mirror,
   and rewriting its URL would silently turn `git push github` into a push back to the
   source site, so the release would never happen and nothing would say so.
2. **Pull the latest code.** `wardner` (the installer itself), `wdnwebui` (the host
   app) and the 8 SDK / plugin packages all fast-forward to the latest on the source
   site.
3. **Re-sync the venv.** Delegated to the host repo's `update_rkwhl.sh`: when HEAD has
   changed it uninstalls and reinstalls, rebuilds the `.so` files of `wdndds` / `wdnav`,
   re-checks card registration and audits the dependencies.

> ⚠️ **The order must not be reversed.** The "pull + decide whether to reinstall" step
> for the 8 SDK packages must be done by `update_rkwhl.sh` itself — it decides whether
> to reinstall by **comparing HEAD before and after the pull**. If `wdn` pulls the code
> first, `update_rkwhl.sh` sees "HEAD has not changed" and skips the reinstall, so the
> `.so` files are not rebuilt (the sources are new, the `.so` files are still the old
> ones).

`wdn` runs with **the python inside the venv** (`~/.wardner/wdnwebui/.venv/bin/python`),
so it can import the SDKs directly for a health check — after an update it automatically
verifies that the four packages `wdnav` / `wdnai` / `wdndds` / `wdnhid` really import.

If the service is still running the old code, restart it after the update:

```bash
wdn stop && wdn start 8080
```

(Or run it in the foreground for the logs — `cd ~/.wardner/wdnwebui && .venv/bin/python run.py`.)

> After the install, the **current** terminal has not picked the PATH up yet — open
> a new terminal, or `source ~/.bashrc` (zsh: `source ~/.zshrc`). A board that
> logs in with zsh never reads `~/.bashrc` — that is why both files are written.
> `wdn doctor` reports the state of both.

---

## The installer never elevates privileges

There is **no privilege-escalation command anywhere in the script**. When a system
dependency is missing (for example cmake / build-essential / patchelf / the foonathan
headers needed to build the `.so` of `wdndds`), it only prints the commands to run,
as-is, for you to run yourself as root:

```
× missing build dependencies: cmake build-essential patchelf libfoonathan-memory-dev
× the .so of wdndds may fail to build (the compute page will report "feature not enabled").
× run the three commands below as root, then re-run this script to build the rest:
×   apt-get update
×   apt-get install -y cmake build-essential patchelf libfoonathan-memory-dev
×   bash ~/.wardner/wdnwebui/update_rkwhl.sh
```

Same thing for the `wdn` command: it is installed for **the person who ran the
installer** (their home directory is `$HOME`).

---

## A few design notes

**Why clone first, then pip-install.** `update_rkwhl.sh` falls back to
`pip install -e git+https://…` when "the directory does not exist". But pip's editable
install from a VCS clones the repo into a temporary directory and points at it — the
temporary directory is deleted right after the install, so the editable install is dead
on arrival (`import` reports `ModuleNotFoundError`), **and pip reports success the
whole way through**. So the installer always clones into `.venv/src/<pkg>/` itself
first, then lets pip install from the local path.

**Why FastDDS is not built over the network.** The `.so` of wdndds is built on site
during installation, but the official prebuilt artifacts of FastDDS 3.6 **ship with the
repo** (`native/lib/`), and the `native/bin/nodesize_dbg` stub is in the repo too — so
a board without internet access can still build the `.so`.

**Why the protocol is decided by the source site, not by the URL the script came from.**
The intranet GitLab's `/raw/` page is http (the web port is 8080), but the code has to
be fetched over **ssh** — tying the protocol to the URL breaks the intranet install.
The other way round, GitHub / Gitee are public repos, and an anonymous clone over
https is the only path that is friendly to "people who are not signed in". The rule is
one line:

| Source site | Protocol | Clone URL |
|---|---|---|
| `github.com` | https | `https://github.com/<org>/<repo>.git` |
| `gitee.com` | https | `https://gitee.com/<org>/<repo>.git` |
| Everything else (intranet) | ssh | `git@<host>:<org>/<repo>.git` |

**Why the package source is configurable.** `WARDNER_PKG_BASE` in `update_rkwhl.sh`
points at the prefix of the package repos; this installer sets it to the **source
site** by default (the organization inferred from the source URL). If your board sits
on an isolated network without internet access, point `WARDNER_PKG_BASE` at your own
mirror:

```bash
WARDNER_PKG_BASE=git+ssh://git@<your-mirror>/<your-path> \
  ~/.wardner/wardner/install.sh
```

If you set `WARDNER_PKG_BASE` explicitly, the installer **will not** overwrite it with
the source site it inferred.

---

## The source address is inferred, not hard-coded

The installer **hard-codes neither the organization nor the source site**. It works
backwards from "which URL did it come from":

1. The `WARDNER_REPO_URL` / `WARDNER_ORG` / `WARDNER_SOURCE_HOST` environment
   variables (explicit override);
2. The `curl` command line — with `curl ... | bash` the script itself does not know
   the source, but curl is usually still running, and its `/proc/<pid>/cmdline` carries
   the full URL;
3. The built-in fallback (GitHub).

After the clone it confirms once more with **the address written in the remote** (the
inference is an inference, the remote is a fact).

So pulling the same script from a fork makes the host app and the 8 SDK / plugin
packages follow that organization; pulling it from Gitee sends everything to Gitee. To
pick another organization or another source site:

```bash
WARDNER_ORG=your-org ~/.wardner/wardner/install.sh
```

The package list itself (`packages.conf`) lives in the repo and travels with it —
adding a package needs no change to the installer.

---

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `WARDNER_HOME` | `~/.wardner` | install root |
| `WARDNER_SELF_SOURCE_URL` | declared by the entry script | the source the **entry script** stands for (`install_github.sh` / `install_gitee.sh` each set their own) — ordinary users never touch it |
| `WARDNER_SOURCE_HOST` | declared by the entry script | source site host (`github.com` / `gitee.com` / intranet address); an explicit value wins |
| `WARDNER_SOURCE_SCHEME` | decided by the source site | `github.com` / `gitee.com` → `https`; everything else → `ssh` |
| `WARDNER_ORG` | inferred from the source site | organization; an explicit value wins |
| `WARDNER_REPO_NAME` | inferred from the source site | name of this repo; an explicit value wins |
| `WARDNER_REPO_URL` | inferred from the source site | URL of this repo — **highest priority**, an explicit value wins. Both a clone URL (`…/wardner.git`) and a file URL (`…/raw/master/install.sh`, normalized automatically) are accepted |
| `WARDNER_HOST_REPO` | `wdnwebui` | host app repo name |
| `WARDNER_PKG_BASE` | `git+https://<source-site>/<org>` | source prefix for the SDK / plugin packages |
| `WARDNER_PYTHON` | `python3` | which python builds the venv |
| `WARDNER_BRANCH` | `master` | which branch to pull |
| `WARDNER_GIT_RETRY` | `5` | clone / pull retry count |
| `WARDNER_RETRY_DELAY` | `5` | delay between retries (seconds) |
| `WARDNER_GIT_LOW_SPEED_LIMIT` | `1` | git low-speed threshold (bytes/second) — below it the transfer counts as broken |
| `WARDNER_GIT_LOW_SPEED_TIME` | `30` | seconds that trigger the low-speed abort (git has no connect timeout by default, a TCP failure waits 135s) |

---

## Adding a new package

1. Create a repo of the same name on the source site (organization `rockchip-wardner`);
2. Add a line to [`packages.conf`](packages.conf): `<package-name> <repo-name>`;
3. Keep the SDKs before the card plugins — the plugins import the SDKs.

---

## Troubleshooting

**The cards do not show up after the install.** The cards are scanned from the entry
points at boot, so restart the service after installing:

```bash
wdn stop && wdn start 8000
```

**The compute page says "功能未启用".** That means the `.so` of `wdndds` was not built.
The installer does not elevate privileges — run the following two commands **as
root**:

```bash
apt-get install -y cmake build-essential patchelf libfoonathan-memory-dev
bash ~/.wardner/wdnwebui/update_rkwhl.sh
```

**The HDMI-IN snapshot endpoint keeps returning 503.** `v4l2` is missing (it only
blows up at import time):

```bash
cd ~/.wardner/wdnwebui
.venv/bin/python scripts/fix_v4l2_py3.py
.venv/bin/python scripts/check_sdk_deps.py    # full dependency audit
```

**The source is wrong (you installed from Gitee, but the preflight says
`source: github.com/…`).** Check that you used the **entry script**: `install_gitee.sh`
is the Gitee source; `install.sh` is the internal implementation and carries **no**
source declaration (it can only guess, and when the guess fails it falls back to
GitHub with a warning):

```bash
curl -fsSL https://gitee.com/rockchip-wardner/wardner/raw/master/install_gitee.sh | bash
```

If you already installed from GitHub, re-running the entry script switches the
source — each repo's remote is moved to the new source automatically:

```bash
curl -fsSL https://gitee.com/rockchip-wardner/wardner/raw/master/install_gitee.sh | bash
```

After the switch, `wdn update` follows the new source too — it reads the address
recorded in this repo's remote.

**Clone times out / GitHub is unreachable.** GitHub is unstable on international
networks; this is common. **Switch to the Gitee mirror** (fast domestically, the
content is identical to GitHub):

```bash
curl -fsSL https://gitee.com/rockchip-wardner/wardner/raw/master/install_gitee.sh | bash
```

If you already installed from GitHub, you can also make `wdn update` go through Gitee:

```bash
WARDNER_SOURCE_HOST=gitee.com wdn update
```

The installer has retries built in (5 times, 5s apart), which usually rides it out. If
it still fails, do it by hand, step by step — every step shows you where it got stuck:

```bash
git clone https://gitee.com/rockchip-wardner/wdnwebui.git ~/.wardner/wdnwebui
git clone https://gitee.com/rockchip-wardner/wdnav.git ~/.wardner/wdnwebui/.venv/src/wdnav
```

> Everything goes over **anonymous HTTPS clone** (GitHub / Gitee): no GitHub account,
> no SSH key — so users who never logged in can install too. The intranet goes over
> ssh (see the protocol table above).

**It will not start after the install: port 8000 is taken.** If another wdnwebui
instance is already running on the board (for example the systemd unit
`wdnwebui.service` pointing at an old install path), starting another one from
`~/.wardner` puts two processes on port 8000. That systemd unit's
`Restart=on-failure` + `RestartSec=5` restarts every 5 seconds, and **each round
SIGTERMs the compute_worker in the cgroup** as well — the symptom is "the worker
finishes loading, and ~9s later it dies", which is easily misdiagnosed as an NPU
loading problem.

Check in this order:

```bash
systemctl status wdnwebui.service     # is there another instance
ss -ltnp | grep :8000                 # who holds the port
```

Pick one, do not run both.

---

## License

Apache-2.0. See [LICENSE](LICENSE).
