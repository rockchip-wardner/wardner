# wdnwebui 一键安装器

Rockchip 平台 Web 服务（[wdnwebui](https://github.com/rockchip-wardner/wdnwebui)）
及其 SDK / 卡片插件的一键安装脚本。

```bash
curl -fsSL https://github.com/rockchip-wardner/wardner/install.sh | bash
```

一条命令把整套装到 `~/.wardner`，建好 venv、装好依赖、编好原生库。

---

## 装完是什么样

```
~/.wardner/
├── wardner/                    本仓（安装器自身）
│   ├── install.sh
│   └── update.sh
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
~/.wardner/wardner/update.sh
```

---

## 它到底做了什么

| 步骤 | 说明 |
|---|---|
| 前置检查 | `git` / `python3`（≥ 3.9）/ `venv` 模块齐不齐 |
| 拉宿主 | clone [wdnwebui](https://github.com/rockchip-wardner/wdnwebui) → `~/.wardner/wdnwebui` |
| 建 venv | `~/.wardner/wdnwebui/.venv` |
| 拉包 | clone 8 个 SDK / 插件仓 → `.venv/src/<pkg>/` |
| 编译依赖 | cmake / build-essential / patchelf / libfoonathan-memory-dev（缺了会提示补装命令） |
| 安装校验 | 交给宿主仓的 `update_rkwhl.sh`（见下） |
| 冒烟 | `import wdnav/wdnai/wdndds/wdnhid` + 断言两个 `.so` 落地 |

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

## 设计上的几个要点

**为什么先 clone 再 pip 装。** `update_rkwhl.sh` 在「目录不存在」时会走
`pip install -e git+https://…`。而 pip 对 VCS 的 editable 安装是把仓库 clone 到
临时目录再指向它 —— 临时目录装完即删，editable 安装当场就废
（`import` 报 `ModuleNotFoundError`），**而 pip 全程报成功**。
所以安装器总是先自己 clone 到 `.venv/src/<pkg>/`，再让 pip 从本地路径装。

**为什么 FastDDS 不用联网编。** wdndds 的 `.so` 是装的时候现场编的，但
FastDDS 3.6 的官方预编译产物**随仓分发**（`native/lib/`），`native/bin/nodesize_dbg`
桩也在仓里 —— 板子没有外网也能编出 `.so`。

**为什么包来源是可配的。** `update_rkwhl.sh` 里 `WARDNER_PKG_BASE` 默认指向公司
内网镜像（现场板子常常没外网）；本安装器把它设成公网 GitHub。想装内网镜像：

```bash
WARDNER_PKG_BASE=git+ssh://git@10.10.10.10/wardner \
  ~/.wardner/wardner/install.sh
```

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `WARDNER_HOME` | `~/.wardner` | 安装根目录 |
| `WARDNER_ORG` | `rockchip-wardner` | GitHub 组织 |
| `WARDNER_REPO_URL` | `https://github.com/rockchip-wardner/wardner.git` | 本仓地址 |
| `WARDNER_HOST_REPO` | `wdnwebui` | 宿主应用仓名 |
| `WARDNER_PKG_BASE` | `git+https://github.com/rockchip-wardner` | SDK / 插件包来源前缀 |
| `WARDNER_PYTHON` | `python3` | 用哪个 python 建 venv |
| `WARDNER_BRANCH` | `master` | 拉哪个分支 |

---

## 加一个新包

1. 在 GitHub 上建同名仓（组织 `rockchip-wardner`）；
2. 在 [`packages.conf`](packages.conf) 加一行：`<包名> <仓名>`；
3. 顺序上 SDK 在前、卡片插件在后 —— 插件会 import SDK。

---

## 排障

**装完卡片没出现。** 卡片是开机时扫 entry point 的，装完要重启服务：

```bash
cd ~/.wardner/wdnwebui && .venv/bin/python run.py
```

**算力页报「功能未启用」。** 说明 `wdndds` 的 `.so` 没编出来：

```bash
sudo apt-get install -y cmake build-essential patchelf libfoonathan-memory-dev
bash ~/.wardner/wdnwebui/update_rkwhl.sh
```

**HDMI-IN 快照端点一直 503。** 缺 `v4l2`（它只在 import 阶段才炸）：

```bash
cd ~/.wardner/wdnwebui
.venv/bin/python scripts/fix_v4l2_py3.py
.venv/bin/python scripts/check_sdk_deps.py    # 全量依赖审计
```

**克隆超时。** GitHub 在部分网络下不稳，可以换 SSH：

```bash
git config --global url."git@github.com:".insteadOf "https://github.com/"
```
