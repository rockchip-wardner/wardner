[English](README.md) | [简体中文](README_CN.md)
# wdnwebui 一键安装器

Rockchip 平台 Web 服务（[wdnwebui](https://github.com/rockchip-wardner/wdnwebui)）
及其 SDK / 卡片插件的一键安装脚本。

---

## 两种安装源

| 源 | 一键命令 | 什么时候用 |
|---|---|---|
| **GitHub** | `curl -fsSL https://github.com/rockchip-wardner/wardner/raw/master/install.sh \| bash` | 默认；国际网络 |
| **Gitee 国内镜像** | `curl -fsSL https://gitee.com/rockchip-wardner/wardner/raw/master/install.sh \| bash` | 国内网络更快 |

> ⚠️ 路径是 **`/raw/master/`**。写成 `.../wardner/install.sh` 拿到的是网页
> 路由，不是原始文件 —— curl 会 404，或者把一段 HTML 喂给 bash。

### 源由你用的那条 URL 决定

安装器**不硬编码组织名，也不硬编码源站** —— 它从「自己是从哪个 URL 拉下来的」
反推：

```
curl 的 URL ──▶ 主机名 ──▶ 源站 ──▶ 传输协议 ──▶ 9 个仓的 clone 地址
```

* **GitHub / Gitee 走 https** —— 公开仓，匿名 clone 就行，不需要账号、
  不需要 SSH key，所以没登录过的用户也能装；
* **内网走 ssh** —— 内网 GitLab 的 web 口在 8080（那是 HTTP 端口），
  取码走 ssh 才是内网该有的方式。

所以**从 Gitee 装的，宿主应用和 8 个 SDK / 插件包、以及后续的 `wdn update`，
全都走 Gitee**；从 GitHub 装的就全走 GitHub。不用配任何环境变量。

> ⚠️ **Gitee 是只读镜像 —— 内容由上游自动同步，不要往它推代码。**
> 推上去的提交会被下一次同步覆盖，而且没有任何提示。需要推送请用
> **GitHub**（或内网主仓库）。
>
> `wdn update` 在 Gitee 源下会把各仓的 **pushurl 单独指回 GitHub** ——
> 拉取走镜像（快），推送走 GitHub（能写）。你没自定义过 pushurl 时它才替你设，
> 设过就一个字都不动。

一条命令把整套装到 `~/.wardner`，建好 venv、装好依赖、编好原生库。

---

## 装完是什么样

```
~/.wardner/
├── wardner/                    本仓（安装器自身）
│   ├── install.sh
│   ├── update.sh
│   ├── bin/wdn                 wdn 命令入口（bash 启动器）
│   └── cli/wdn.py              wdn 的真正实现（用 .venv 的 python 跑）
└── wdnwebui/                   宿主应用（FastAPI 服务 + 卡片宿主）
    ├── app/  run.py  ...
    ├── requirements.txt
    └── .venv/                  虚拟环境
        ├── bin/python
        └── src/                SDK / 卡片插件包（各自独立 git 仓）
            ├── wdnav/          MPP / RGA2 / V4L2 视频
            ├── wdnai/          RKNN LLM / VLM / TTS
            ├── wdndds/         DDS / RPC（模型隔离）
            ├── wdnhid/         USB Gadget HID
            ├── wdnapps_video_analyzer/
            ├── wdnapps_hdmi_processor/
            ├── wdnapps_audio_chat/
            └── wdnapps_media_generator/
```

启动：

```bash
cd ~/.wardner/wdnwebui
.venv/bin/python run.py        # http://<板子IP>:8000/
```

更新：

```bash
wdn update                     # 推荐：更新所有仓 + 重新同步 venv
```

也可以用脚本：

```bash
~/.wardner/wardner/update.sh
```

---

## 它到底做了什么

| 步骤 | 说明 |
|---|---|
| 前置检查 | `git` / `python3`（≥ 3.9）/ `venv` 模块齐不齐 |
| 拉宿主 | clone [wdnwebui](https://github.com/rockchip-wardner/wdnwebui) → `~/.wardner/wdnwebui`（**跟着源站走**） |
| 建 venv | `~/.wardner/wdnwebui/.venv` |
| 拉包 | clone 8 个 SDK / 插件仓 → `.venv/src/<pkg>/`（**跟着源站走**） |
| 编译依赖 | cmake / build-essential / patchelf / libfoonathan-memory-dev（缺了会提示补装命令） |
| 安装校验 | 交给宿主仓的 `update_rkwhl.sh`（见下） |
| 冒烟 | `import wdnav/wdnai/wdndds/wdnhid` + 断言两个 `.so` 落地 |
| 装 wdn | 命令挂进 PATH，并把环境写进 `~/.bashrc`（见下） |

**安装与校验没有在本仓重写** —— 直接调用宿主仓里的
[`update_rkwhl.sh`](https://github.com/rockchip-wardner/wdnwebui/blob/master/update_rkwhl.sh)。
那 470 行是在板子上打磨出来的，装的是它已经在做的事：

- 装 `requirements.txt`（web 侧依赖）
- 修补 PyPI 上 `v4l2`（2014 年 py2 时代 sdist）的 py3 兼容问题
- 逐包 `git pull` + editable 重装（HEAD 没变就跳过）
- **断言 `wdndds` / `wdnav` 的 `.so` 真的落地了** —— setuptools ≥64 会静默吞掉
  build hook 的 RuntimeError，pip 照样返回 0、满屏绿色，但产物根本没生成
- **校验 4 个插件包的卡片真的注册上了** —— entry point 名 ↔ manifest `"id"` ↔
  `static/` 三段链路；不一致时 pip 全程报成功，宿主启动却把这几张卡 FATAL 跳过
- **审计各 SDK 自己声明的依赖** —— SDK 是 `--no-deps` 装的，声明的依赖不会自己
  进 venv，而故障现场离原因很远（缺 v4l2 → HDMI-IN 端点 503；缺 tokenizers →
  算力页「模型启动失败」）

---

## `wdn` 命令

装完就有 —— PATH 已经写进 `~/.bashrc`，当前用户直接用：

```bash
wdn update      # 把所有已下载的仓更新到源站最新，并重新同步 venv
wdn status      # 看各仓的 commit / remote 和 venv 状态
wdn version     # 版本号
```

### `wdn update` 做三件事

1. **对齐 remote 到源站。** 各仓的 remote 可能指着别处（内网镜像 / 另一个站），
   改回**源站**—— 源站是哪个，由本仓的 remote 决定，从哪儿装的还走哪儿。
   分支跟踪关系只在「当前跟踪的 remote 不指向源站」时才动 —— 跟踪关系
   同时也是你的推送路径，擅自改会让 `git push` 悄悄改道。想完全不动 remote
   就加 `--keep-remotes`。
   名为 **`github`** 的远端**不动** —— 它是「只 push」的发布镜像，改写它的 URL
   会让 `git push github` 悄悄推回源站，发布根本没发生且毫无提示。
2. **拉最新代码。** `wardner`（安装器自己）、`wdnwebui`（宿主）、8 个 SDK /
   插件包，全部快进到源站的最新。
3. **重新同步 venv。** 交给宿主仓的 `update_rkwhl.sh`：HEAD 变了就卸载重装，
   并重编 `wdndds` / `wdnav` 的 `.so`、复核卡片注册、审计依赖。

> ⚠️ **顺序不能反。** 8 个 SDK 包的「pull + 判断要不要重装」必须由
> `update_rkwhl.sh` 自己来做 —— 它靠 **pull 前后的 HEAD 对比**判断要不要
> 重装。如果 `wdn` 先把代码拉到最新，`update_rkwhl.sh` 就会看到「HEAD 没变」
> 而跳过重装，`.so` 不会重新编（源码是新的、`.so` 还是旧的）。

`wdn` 用的是 **venv 里的 python**（`~/.wardner/wdnwebui/.venv/bin/python`），
所以它能直接 import SDK 做健康检查 —— 更新完会自动验证 `wdnav` / `wdnai` /
`wdndds` / `wdnhid` 四个包是不是真能 import。

服务还在跑旧代码的话，更新完重启它：

```bash
cd ~/.wardner/wdnwebui && .venv/bin/python run.py
```

> 改了 `~/.bashrc` 之后，**当前**终端还没生效 —— 新开一个终端，或
> `source ~/.bashrc`。

---

## 安装器不自行提权

脚本里**没有任何提权命令**。缺系统依赖（比如编译 `wdndds` 的 `.so` 要
cmake / build-essential / patchelf / foonathan 头文件）时，它只把要执行的
命令原样打出来，由你自己以 root 身份跑：

```
× 缺编译依赖： cmake build-essential patchelf libfoonathan-memory-dev
× wdndds 的 .so 可能编不出来（算力页会报「功能未启用」）。
× 请以 root 身份执行下面三条，然后重跑本脚本补编：
×   apt-get update
×   apt-get install -y cmake build-essential patchelf libfoonathan-memory-dev
×   bash ~/.wardner/wdnwebui/update_rkwhl.sh
```

同理，`wdn` 命令也是装给**跑安装器的那个人**（家目录就是 `$HOME`）。

---

## 设计上的几个要点

**为什么先 clone 再 pip 装。** `update_rkwhl.sh` 在「目录不存在」时会走
`pip install -e git+https://…`。而 pip 对 VCS 的 editable 安装是把仓库 clone 到
临时目录再指向它 —— 临时目录装完即删，editable 安装当场就废
（`import` 报 `ModuleNotFoundError`），**而 pip 全程报成功**。
所以安装器总是先自己 clone 到 `.venv/src/<pkg>/`，再让 pip 从本地路径装。

**为什么 FastDDS 不用联网编。** wdndds 的 `.so` 是装的时候现场编的，但
FastDDS 3.6 的官方预编译产物**随仓分发**（`native/lib/`），`native/bin/nodesize_dbg`
桩也在仓里 —— 板子没有外网也能编出 `.so`。

**为什么协议由源站决定，而不是由取脚本的 URL 决定。** 内网 GitLab 的
`/raw/` 页面是 http 的（web 口在 8080），但代码要从 **ssh** 拉 —— 协议跟着
URL 走会让内网装不上。反过来 GitHub / Gitee 是公开仓，走 https 匿名 clone
才是对「没登录的人」友好的唯一路径。规则就一条：

| 源站 | 协议 | clone 地址 |
|---|---|---|
| `github.com` | https | `https://github.com/<org>/<repo>.git` |
| `gitee.com` | https | `https://gitee.com/<org>/<repo>.git` |
| 其余（内网） | ssh | `git@<host>:<org>/<repo>.git` |

**为什么包来源是可配的。** `update_rkwhl.sh` 里 `WARDNER_PKG_BASE` 指向包仓库
的前缀，本安装器默认把它设成**源站**（由来源 URL 推断出的组织）。如果你的板子
在无外网的隔离网络里，用 `WARDNER_PKG_BASE` 指向你自己的镜像：

```bash
WARDNER_PKG_BASE=git+ssh://git@<your-mirror>/<your-path> \
  ~/.wardner/wardner/install.sh
```

显式给了 `WARDNER_PKG_BASE` 的，安装器**不会**用它推断出来的源站覆盖它。

---

## 源地址是「推断」出来的，不是写死的

安装器**不硬编码组织名，也不硬编码源站**。它从「自己是从哪个 URL 拉下来的」反推：

1. `WARDNER_REPO_URL` / `WARDNER_ORG` / `WARDNER_SOURCE_HOST` 环境变量（显式覆盖）；
2. `curl` 的命令行 —— `curl ... | bash` 时脚本本身不知道来源，但 curl 通常还在
   跑，它的 `/proc/<pid>/cmdline` 里带着完整 URL；
3. 内置兜底（GitHub）。

clone 之后还会用 **remote 里写着的地址**再确认一次（推断归推断，remote 是事实）。

所以从 fork 拉同一个脚本，宿主应用和 8 个 SDK / 插件包都会跟着走那个组织；
从 Gitee 拉，就全都走 Gitee。想指定别的组织或别的源站：

```bash
WARDNER_ORG=your-org ~/.wardner/wardner/install.sh
```

包清单本身（`packages.conf`）就在仓里，跟着仓走 —— 加包不用改安装器。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `WARDNER_HOME` | `~/.wardner` | 安装根目录 |
| `WARDNER_SOURCE_HOST` | 由来源 URL 推断 | 源站主机（`github.com` / `gitee.com` / 内网地址） |
| `WARDNER_SOURCE_SCHEME` | 由源站决定 | `github.com` / `gitee.com` → `https`；其余 → `ssh` |
| `WARDNER_ORG` | 由来源 URL 推断 | 组织 |
| `WARDNER_REPO_NAME` | 由来源 URL 推断 | 本仓名 |
| `WARDNER_REPO_URL` | 由来源 URL 推断 | 本仓地址 |
| `WARDNER_HOST_REPO` | `wdnwebui` | 宿主应用仓名 |
| `WARDNER_PKG_BASE` | `git+https://<源站>/<组织>` | SDK / 插件包来源前缀 |
| `WARDNER_PYTHON` | `python3` | 用哪个 python 建 venv |
| `WARDNER_BRANCH` | `master` | 拉哪个分支 |
| `WARDNER_GIT_RETRY` | `5` | clone / pull 重试次数 |
| `WARDNER_RETRY_DELAY` | `5` | 重试间隔（秒） |
| `WARDNER_GIT_LOW_SPEED_LIMIT` | `1` | git 低速阈值（字节/秒）—— 低于它就算断 |
| `WARDNER_GIT_LOW_SPEED_TIME` | `30` | 触发低速中断的秒数（git 默认没有连接超时，TCP 失败要等 135s） |

---

## 加一个新包

1. 在源站上建同名仓（组织 `rockchip-wardner`）；
2. 在 [`packages.conf`](packages.conf) 加一行：`<包名> <仓名>`；
3. 顺序上 SDK 在前、卡片插件在后 —— 插件会 import SDK。

---

## 排障

**装完卡片没出现。** 卡片是开机时扫 entry point 的，装完要重启服务：

```bash
cd ~/.wardner/wdnwebui && .venv/bin/python run.py
```

**算力页报「功能未启用」。** 说明 `wdndds` 的 `.so` 没编出来。安装器不自行
提权，下面两条**以 root 身份**执行：

```bash
apt-get install -y cmake build-essential patchelf libfoonathan-memory-dev
bash ~/.wardner/wdnwebui/update_rkwhl.sh
```

**HDMI-IN 快照端点一直 503。** 缺 `v4l2`（它只在 import 阶段才炸）：

```bash
cd ~/.wardner/wdnwebui
.venv/bin/python scripts/fix_v4l2_py3.py
.venv/bin/python scripts/check_sdk_deps.py    # 全量依赖审计
```

**克隆超时 / GitHub 连不上。** 国际网络下 GitHub 不稳很常见。**直接改用 Gitee
镜像**（国内快，代码内容与 GitHub 一致）：

```bash
curl -fsSL https://gitee.com/rockchip-wardner/wardner/raw/master/install.sh | bash
```

已经用 GitHub 装好的，也可以让 `wdn update` 改走 Gitee：

```bash
WARDNER_SOURCE_HOST=gitee.com wdn update
```

安装器自带重试（5 次，间隔 5s），一般能扛过去。仍不行就手动分步来，每一步
都能看清卡在哪：

```bash
git clone https://gitee.com/rockchip-wardner/wdnwebui.git ~/.wardner/wdnwebui
git clone https://gitee.com/rockchip-wardner/wdnav.git ~/.wardner/wdnwebui/.venv/src/wdnav
```

> 全程走 **HTTPS 匿名 clone**（GitHub / Gitee），不需要 GitHub 账号、不需要
> SSH key —— 所以没登录过的用户也能装。内网则走 ssh（见上面的协议表）。

**装完起不来：端口 8000 被占。** 板子上如果已经有另一个 wdnwebui 实例在跑
（比如 systemd 单元 `wdnwebui.service` 指向旧的安装路径），再从 `~/.wardner`
起一个就会两个进程抢 8000。systemd 那个 `Restart=on-failure` +
`RestartSec=5` 会每 5 秒重启一轮，而且**每轮都把 cgroup 里的 compute_worker
一起 SIGTERM 掉** —— 症状是「worker 加载完 ~33s 后 ~9s 就死」，很容易被
误判成 NPU 加载有问题。

排查顺序：

```bash
systemctl status wdnwebui.service     # 有没有另一个实例
ss -ltnp | grep :8000                 # 谁占着端口
```

二选一，别同时跑。

---

## License

Apache-2.0。见 [LICENSE](LICENSE)。
