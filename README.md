# DeepSeek Harness Window（社区版 · fork v1.3.0）

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI 装进 **Windows 原生独立窗口**（WebView2，即 Edge 内核）的极简启动器。

<p align="center">
  <a href="https://github.com/anglesccs/dsh-window"><img alt="GitHub stars" src="https://img.shields.io/github/stars/anglesccs/dsh-window?style=flat-square&color=4b6fff"></a>
  <a href="https://www.npmjs.com/package/dsh-window-community"><img alt="npm" src="https://img.shields.io/npm/v/dsh-window-community?style=flat-square&color=cb3837"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-263146?style=flat-square"></a>
  <a href="https://awesome-dsh-plugin.com"><img alt="Awesome DSH Plugin" src="https://awesome-dsh-plugin.com/badge.svg"></a>
  <img alt="platform" src="https://img.shields.io/badge/Windows%2010%2F11-4493F8?style=flat-square">
</p>

<p align="center"><strong>简体中文</strong> | <a href="#english">English</a></p>

<p align="center">
  <img src="assets/screenshot.png" alt="DeepSeek Harness Window 界面预览" width="640">
</p>

- 没有浏览器标签栏、地址栏；任务栏上是自己的图标和窗口
- 不需要 Electron；精简版整个应用约 256KB（4 个程序文件，另附示例配置）
- **外部服务器模式**：DSH 跑在局域网另一台机器上时，Windows 这边只做「窗口 + 托盘 + 断线自恢复」，不需要 Node、不需要 DSH
- **便携版双击即用**：自带 Node.js + DSH + Git，无需安装任何环境（仅本地模式需要）
- 双击即用：自动检测/启动本地 DSH 服务，就绪后弹窗；关窗即停（服务由它启动时）
- 单实例：重复双击只聚焦已有窗口；记住窗口大小和位置；连不上服务时自动退避重试（2/5/10/30 秒）

> ⚠️ **非官方社区项目**，与 DeepSeek 公司无隶属关系。"DeepSeek" 商标归其所有者所有。

## 快速开始

**方式一：外部服务器模式（推荐：DSH 不在本机跑）**

1. 从 [Releases](../../releases) 下载精简包 `DeepSeek-Harness-Window-v*-win-x64.zip`（4 个程序文件 + 示例配置，约 256KB）
2. 解压到任意目录，把 `dsh-window.config.example.json` 复制成 `dsh-window.config.json`
3. 改成你的远程地址（必须带协议，可带路径；末尾斜杠会自动补）：

```json
{
  "serverMode": "external",
  "externalUrl": "http://192.168.78.2:3080/"
}
```

4. 双击 `DeepSeek Harness Window.exe`

`serverMode` 为 `"external"` 时程序**只连远程**：不解析本地运行时、不启动也不结束任何进程；关窗不会影响服务器。断线时窗口内显示错误页并自动重试（第 1/2/3 次分别等 2/5/10 秒，之后固定 30 秒；睡眠唤醒后立即重试一次）。想常驻托盘就加 `"closeToTray": true`。

**方式二：本地模式（需要 Node + DSH）**

1. 下载 `DeepSeek-Harness-Window-v*-win-x64.zip` 并解压（4 个程序文件）
2. 前提：Windows 10/11、Node.js 装在默认位置 `%LOCALAPPDATA%\Programs\nodejs`、`npm install -g @deepseek-ai/dsh`
3. 双击 `DeepSeek Harness Window.exe`（不写 `serverMode` 时默认就是 `local`）
4. 想一键安装到系统（开始菜单 + 桌面快捷方式 + 控制面板可卸载）：运行 `DeepSeek Harness Window.exe --install`，卸载用 `--uninstall`

> 想零安装体验也可以用便携版（自带 Node.js + DSH + Git，约 180MB）：下载 `DeepSeek-Harness-Window-portable-v*-win-x64.zip`，解压双击即可。

**方式三：DSH 插件（已装 DSH、想让 agent 帮你拉起桌面窗口）**

```sh
dsh plugin --profile web add github:anglesccs/dsh-window#path:/plugin
```

插件默认从本 fork 的 Releases 安装（`repoSlug` 默认 `anglesccs/dsh-window`）。

插件自动从 GitHub Releases 安装应用并创建桌面快捷方式「DeepSeek Harness Window」；对话里说"打开桌面应用"即可通过 `desktop_launch` 工具拉起。详见 [plugin/README.md](plugin/README.md)。

> ⚠️ **不要**用 `dsh plugin --profile web add dsh-window`：npm 上的 `dsh-window` 是**别人的同名包**（`bbtssama/dsh-window`，Typora 风格便签）。本插件在 npm 上叫 `dsh-window-community`，用上面的 `github:` 命令安装最稳。

**便携版（零门槛，任何人）**

1. 从 [Releases](../../releases) 下载 `DeepSeek-Harness-Window-portable-v*-win-x64.zip`
2. 解压到任意目录
3. 双击 `DeepSeek Harness Window.exe`

> 首次运行 Windows SmartScreen 可能拦截（exe 未签名）：点「更多信息 → 仍要运行」即可。

## 三件套全家桶（桌面 + GLM 视觉 + 语音输入）

一条命令装齐「Windows 桌面窗口 + DeepEye 视觉（GLM-4V-Flash）+ 语音输入按钮」：

```sh
dsh plugin --profile web add github:anglesccs/dsh-window#path:/kit
```

GLM 视觉需在 `~/.dsh/.env` 配置 `DEEPEYE_API_KEY`（智谱开放平台）。详见 [kit/README.md](kit/README.md)。

## 两种形态

| | 精简版 slim | 便携版 portable |
| --- | --- | --- |
| 大小 | ~256KB | ~180MB |
| 适合 | 开发者；**外部服务器模式**（DSH 在别的机器上） | 本地模式、零安装体验 |
| 前提 | 外部模式无；本地模式需 Node + `npm i -g @deepseek-ai/dsh` | 无 |
| 文件名 | `DeepSeek-Harness-Window-v*-win-x64.zip` | `...-portable-v*-win-x64.zip` |

## 同类桌面壳对比

| | **dsh-window** | [dsh-desktop-windowos](https://github.com/RAFOLIE/dsh-desktop-windowos) | [DeepSeek Harness Desktop](https://github.com/anywhere-labs/deepseek-harness-desktop) |
| --- | --- | --- | --- |
| 安装 | `dsh plugin add github:anglesccs/dsh-window#path:/plugin` / zip | 插件 / 单 exe | 官网安装包 |
| 体积 | 256KB（精简）/ 180MB（便携） | 约 4.5MB | 安装包 |
| 需要 Node | 仅本地模式需要；**外部服务器模式不需要** | 需要 | 不需要 |
| 技术栈 | C# + WebView2（系统自带 csc 即可编译） | Tauri v2 + React | Electron |
| 托盘 / 任务完成通知 | 托盘有（`closeToTray`）；通知计划中 | 有 | 有 |

## 原理

DeepSeek Harness 的图形界面本质是一个网页（本地默认 `http://127.0.0.1:3080`）。本程序把"打开浏览器标签页"这一步换成内嵌的 WebView2 窗口：

- **local 模式**（默认）：必要时起服务（`dsh --profile web --host 127.0.0.1 --port 3080`），就绪后开窗；服务由它启动且 `killServerOnClose` 为真时关窗一并停止。便携版把运行环境（Node、DSH 包、Git）放在 `runtime\` 下优先使用，找不到再回退到系统安装。
- **external 模式**：DSH 在别的机器上（如 `http://192.168.78.2:3080`），本机只做客户端——**不解析运行时、不 spawn、不 kill**，断线自动退避重连。适合 Windows 只是"看板机"的场景。

local 模式下 `host` 必须是本机地址（`127.0.0.1`、`localhost`、`::1`、`0.0.0.0` 等）；写成远程 IP 会被拒绝 spawn（那种情况请改用 external 模式）。

## 可选配置

在 exe 同目录放一个 `dsh-window.config.json`（可省略，全部有默认值）：

```json
{
  "serverMode": "local",
  "externalUrl": "",
  "host": "127.0.0.1",
  "port": 3080,
  "waitTimeoutMs": 30000,
  "killServerOnClose": true,
  "permissionMode": "danger-full-access",
  "closeToTray": true,
  "checkUpdates": true,
  "updateRepo": "anglesccs/dsh-window",
  "logFile": true
}
```

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `serverMode` | `local` | `local`=必要时拉起本地 DSH；`external`=只连 `externalUrl`，绝不解析运行时/不 spawn/不 kill。非法值回落 `local` 并记日志 |
| `externalUrl` | 空 | 非空则直接作为窗口地址（允许 `https://`、允许带路径），并**强制 external 模式**；末尾无斜杠会自动补 |
| `host` / `port` | `127.0.0.1` / `3080` | 服务地址；改端口即可与其它实例共存 |
| `waitTimeoutMs` | `30000` | 等待服务就绪的超时 |
| `killServerOnClose` | `true` | 服务由本程序启动时，关窗是否一并停止 |
| `permissionMode` | `danger-full-access` | 传给服务的 DSH 权限模式（也可在 Web UI 里改） |
| `closeToTray` | `false` | 点关闭按钮最小化到托盘（托盘菜单：显示主窗口 / 退出） |
| `checkUpdates` | `true` | 启动后检查 GitHub Release 新版本，有新版时页面右下角提示 |
| `updateRepo` | `anglesccs/dsh-window` | 更新检查的仓库 |
| `logFile` | `false` | 写日志到 `%LOCALAPPDATA%\DeepSeekHarnessWindow\launcher.log` |

## 命令行参数

| 参数 | 作用 |
| --- | --- |
| （无） | 确保服务在线，然后打开窗口 |
| `--check [--out <path>]` | 无界面自检：不建窗口、不弹窗、不 spawn；external 模式只探 URL。`--out` 写 UTF-8 无 BOM 的 JSON 报告。退出码 0=通过 / 2=有问题 |
| `--no-window` | 只确保服务在线，不打开窗口 |
| `--install` | 一键安装：拷贝到 `%LOCALAPPDATA%\Programs\dsh-window`，创建桌面/开始菜单快捷方式和卸载项 |
| `--uninstall` | 卸载：移除快捷方式、注册表卸载项与安装目录 |

## 从源码构建

依赖：Windows + PowerShell + .NET Framework 4.x（自带 `csc.exe`）。构建脚本自动下载 WebView2 SDK（NuGet）。

```powershell
.\build.ps1                          # 精简版
.\build.ps1 -Portable                # 精简版 + 便携版（自动下载 Node/MinGit、npm 安装 DSH）
.\build.ps1 -Version 1.3.0 -IconPath .\my-icon.ico
.\build.ps1 -Portable -DshVersion 0.1.0-rc.6 -NpmRegistry https://registry.npmmirror.com
```

产物：`dist\`（精简版目录）、`dist-portable\`（便携版目录）及仓库根目录下的 zip。

> 图标是可选的。仓库内不带任何 DeepSeek 官方 logo 素材，请勿在公开分发中使用官方鲸鱼 logo，除非你确认有权使用。

## 常见问题

**便携版为什么这么大？**
Node.js 运行时 + 完整 `@deepseek-ai/dsh` 包 + MinGit。这是"解压即用"的代价；不需要零安装体验就用精简版。**只做远程客户端（external 模式）时完全不需要便携版**——精简版 4 个文件就够。

**和直接开浏览器有什么区别？**
服务完全一样，会话数据完全共用（`~/.dsh`）。区别只在窗口形态：独立窗口、独立任务栏图标；local 模式下关窗即停（服务由它启动时）。

**关掉窗口后还能用浏览器访问吗？**
如果服务本来就在外面跑着（比如命令行 `dsh web`，或者 external 模式连的远程机器），关窗不影响；只有服务是这个程序起的且 `killServerOnClose` 为 `true` 时才会一起停。

**为什么不是单文件 exe？**
WebView2 需要 3 个运行库文件随 exe 分发（含一个原生 DLL）。4 个文件放一个文件夹，体感与单文件无异。

**Windows 弹 SmartScreen 警告？**
exe 未做代码签名，首次运行会被拦：点「更多信息 → 仍要运行」。签名在 Roadmap 中。

## Roadmap

- [x] 作为 DSH 插件分发（`dsh plugin add github:anglesccs/dsh-window#path:/plugin`，含 `desktop_launch` 工具与自动安装/升级）
- [x] 外部服务器模式（`serverMode: "external"` + `externalUrl`）：不依赖本地 Node，断线自动退避重连，睡眠唤醒即时重试
- [x] 托盘常驻与最小化到托盘（`closeToTray`，点关闭按钮隐藏到托盘）
- [x] 自动检查新版本并在页面内提示（`checkUpdates`）
- [x] 一键安装/卸载（`--install` / `--uninstall`，开始菜单 + 桌面快捷方式 + 控制面板卸载项）
- [ ] 任务完成系统通知（会话 idle 时弹 Toast，可一键唤回窗口）
- [ ] Inno Setup / winget 安装包
- [ ] 代码签名（消除 SmartScreen 警告）

## 相关链接

- 官方仓库：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（MIT，Discussions 开放）
- 官方 npm 包：[`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)
- 插件精选列表：[awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin)
- 其他社区桌面壳：[RAFOLIE/dsh-desktop-windowos](https://github.com/RAFOLIE/dsh-desktop-windowos)、[anywhere-labs/deepseek-harness-desktop](https://github.com/anywhere-labs/deepseek-harness-desktop)、[salathleizhang/deepseek-harness-desktop](https://github.com/salathleizhang/deepseek-harness-desktop)、[ChisaAlter/Deepseek-Harness-Desktop](https://github.com/ChisaAlter/Deepseek-Harness-Desktop)

## License

MIT（见 [LICENSE](LICENSE)）

---

<a id="english"></a>

# DeepSeek Harness Window (community edition)

A minimal launcher that puts the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Web UI into a **native standalone Windows window** (WebView2 / Edge engine).

<p align="center">
  <img src="assets/screenshot.png" alt="DeepSeek Harness Window preview" width="640">
</p>

- No browser tabs or address bar; its own taskbar icon and window
- No Electron; the slim build is ~256KB (4 program files plus an example config)
- **External-server mode**: when DSH runs on another machine (e.g. `http://192.168.78.2:3080`), the Windows side is only a window + tray + auto-reconnect client — no Node, no DSH
- **Portable build, double-click and go**: bundles Node.js + DSH + Git, no environment required (local mode only)
- Auto-detects/starts the local DSH service and opens the window when ready; closes the service on exit only when it started it
- Single instance: re-launching focuses the existing window; remembers size/position; automatic backoff retry (2/5/10/30s) when the service is unreachable

> ⚠️ **Community project**, not affiliated with DeepSeek. The "DeepSeek" trademark belongs to its owners.

## Quick start

**Option A: external-server mode (recommended when DSH runs on another machine)**

1. Download the slim zip `DeepSeek-Harness-Window-v*-win-x64.zip` from [Releases](../../releases) (4 program files + example config, ~256KB)
2. Unzip anywhere and copy `dsh-window.config.example.json` to `dsh-window.config.json`
3. Point it at your remote server:

```json
{
  "serverMode": "external",
  "externalUrl": "http://192.168.78.2:3080/"
}
```

4. Double-click `DeepSeek Harness Window.exe`

With `serverMode: "external"` the app is a pure client: it never resolves a local runtime, never spawns or kills a process, and closing it leaves the server untouched. On failure the window shows the built-in error page and retries after 2s, 5s, 10s, then every 30s; waking from sleep retries immediately. Add `"closeToTray": true` to keep it in the tray.

**Option B: local mode (Node + DSH on this machine)**

1. Download and unzip `DeepSeek-Harness-Window-v*-win-x64.zip` (4 program files)
2. Prerequisites: Windows 10/11, Node.js at `%LOCALAPPDATA%\Programs\nodejs`, `npm install -g @deepseek-ai/dsh`
3. Double-click `DeepSeek Harness Window.exe` (`local` is the default when `serverMode` is absent)
4. To install system-wide (start menu + desktop shortcut + control-panel uninstaller): run `DeepSeek Harness Window.exe --install`; remove with `--uninstall`

**Option C: DSH plugin (agent-driven launch)**

```sh
dsh plugin --profile web add github:anglesccs/dsh-window#path:/plugin
```

The plugin installs from this fork's Releases by default (`repoSlug` defaults to `anglesccs/dsh-window`).

The plugin auto-installs the app from GitHub Releases and creates the desktop shortcut "DeepSeek Harness Window"; say "open the desktop app" in chat to launch it via the `desktop_launch` tool. See [plugin/README.md](plugin/README.md).

> ⚠️ Do **not** run `dsh plugin --profile web add dsh-window`: the npm package `dsh-window` is someone else's project (`bbtssama/dsh-window`). This plugin is named `dsh-window-community`.

**Portable build (anyone, zero prerequisites)**

1. Download `DeepSeek-Harness-Window-portable-v*-win-x64.zip` from [Releases](../../releases)
2. Unzip anywhere
3. Double-click `DeepSeek Harness Window.exe`

> First run may hit SmartScreen (the exe is unsigned): click "More info → Run anyway".

## All-in-one kit (desktop + GLM vision + voice input)

One command installs the Windows desktop window, DeepEye vision (GLM-4V-Flash), and the voice-input mic button:

```sh
dsh plugin --profile web add github:anglesccs/dsh-window#path:/kit
```

Set `DEEPEYE_API_KEY` in `~/.dsh/.env` (Zhipu open platform) for vision. See [kit/README.md](kit/README.md).

## Builds

| | slim | portable |
| --- | --- | --- |
| Size | ~256KB | ~180MB |
| For | developers; **external-server mode** (DSH elsewhere) | local mode, unzip-and-go |
| Prerequisites | none in external mode; Node + `npm i -g @deepseek-ai/dsh` in local mode | none |
| File | `DeepSeek-Harness-Window-v*-win-x64.zip` | `...-portable-v*-win-x64.zip` |

## How it works

The DeepSeek Harness GUI is a web page (default `http://127.0.0.1:3080`). This app replaces the "open a browser tab" step with an embedded WebView2 window:

- **local mode** (default): starts the service when needed (`dsh --profile web --host 127.0.0.1 --port 3080`); stops it on close when it started it and `killServerOnClose` is true. The portable build keeps the runtime (Node, the DSH package, Git) under `runtime\` and falls back to the system install when missing.
- **external mode**: DSH runs elsewhere (e.g. `http://192.168.78.2:3080`); this machine is a pure client — no runtime resolution, no spawn, no kill — with automatic backoff reconnects.

In local mode `host` must be a local address (`127.0.0.1`, `localhost`, `::1`, `0.0.0.0`, …); a remote IP is refused instead of spawning a node process that cannot bind. Use external mode for that.

## Optional config

Drop a `dsh-window.config.json` next to the exe (all keys optional):

```json
{
  "serverMode": "local",
  "externalUrl": "",
  "host": "127.0.0.1",
  "port": 3080,
  "waitTimeoutMs": 30000,
  "killServerOnClose": true,
  "permissionMode": "danger-full-access",
  "closeToTray": true,
  "checkUpdates": true,
  "updateRepo": "anglesccs/dsh-window",
  "logFile": true
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `serverMode` | `local` | `local` = start DSH when needed; `external` = only connect to `externalUrl` (never resolve/spawn/kill). Invalid values fall back to `local` with a log warning |
| `externalUrl` | empty | When non-empty, used as the window URL (http/https, paths allowed) and forces external mode; a missing trailing slash is added |
| `host` / `port` | `127.0.0.1` / `3080` | Service address; change the port to coexist with other instances |
| `waitTimeoutMs` | `30000` | Service readiness timeout |
| `killServerOnClose` | `true` | Stop the service on window close when this app started it |
| `permissionMode` | `danger-full-access` | DSH permission mode passed to the service (changeable in the Web UI) |
| `closeToTray` | `false` | Minimize to tray on close (tray menu: show window / quit) |
| `checkUpdates` | `true` | Check GitHub Releases on startup and show an in-page banner when a new version exists |
| `updateRepo` | `anglesccs/dsh-window` | Repository used for the update check |
| `logFile` | `false` | Write logs to `%LOCALAPPDATA%\DeepSeekHarnessWindow\launcher.log` |

## Command-line arguments

| Argument | Effect |
| --- | --- |
| (none) | Ensure the service is online, then open the window |
| `--check [--out <path>]` | Headless self-check: no window, no dialogs, no spawn; external mode only probes the URL. `--out` writes a UTF-8 (no BOM) JSON report. Exit 0 = ok, 2 = problems |
| `--no-window` | Only ensure the service is online, open no window |
| `--install` | One-click install: copies to `%LOCALAPPDATA%\Programs\dsh-window`, creates desktop/start-menu shortcuts and an uninstall entry |
| `--uninstall` | Uninstall: removes shortcuts, the registry entry, and the install directory |

## Building from source

Prerequisites: Windows + PowerShell + .NET Framework 4.x (bundled `csc.exe`). The build script downloads the WebView2 SDK (NuGet) automatically.

```powershell
.\build.ps1                          # slim build
.\build.ps1 -Portable                # slim + portable (downloads Node/MinGit, npm-installs DSH)
.\build.ps1 -Version 1.3.0 -IconPath .\my-icon.ico
.\build.ps1 -Portable -DshVersion 0.1.0-rc.6 -NpmRegistry https://registry.npmmirror.com
```

Output: `dist\` (slim), `dist-portable\` (portable), and zips in the repo root.

> The icon is optional. This repo ships no DeepSeek logo assets; do not use the official whale logo in public distribution unless you are sure you have the rights.

## FAQ

**Why is the portable build so big?**
Node.js runtime + the full `@deepseek-ai/dsh` package + MinGit. That is the price of unzip-and-go; use the slim build when you already have Node. A remote-only client (external mode) does not need the portable build at all.

**How is this different from opening a browser?**
The service is identical and sessions are fully shared (`~/.dsh`). The difference is window chrome only: standalone window, own taskbar icon; in local mode closing stops the service it started.

**Can I still use the browser after closing the window?**
Yes, when the service was already running externally (e.g. `dsh web` in a terminal, or a remote host in external mode). When this app started the service and `killServerOnClose` is `true`, closing the window stops it.

**Why not a single-file exe?**
WebView2 needs 3 runtime files shipped beside the exe (including a native DLL). Four files in one folder feel the same as a single file.

**Windows shows a SmartScreen warning?**
The exe is not code-signed yet, so the first run is blocked: click "More info → Run anyway". Signing is on the roadmap.

## Roadmap

- [x] DSH plugin distribution (`dsh plugin add github:anglesccs/dsh-window#path:/plugin`, `desktop_launch` tool, auto-install/upgrade)
- [x] External-server mode (`serverMode: "external"` + `externalUrl`): no local Node needed, backoff reconnects, immediate retry on wake
- [x] Tray residency and minimize-to-tray (`closeToTray`, X button hides to tray)
- [x] Automatic update check with an in-page banner (`checkUpdates`)
- [x] One-click install/uninstall (`--install` / `--uninstall`, start-menu + desktop shortcuts, control-panel entry)
- [ ] Task-done system notification (toast when the session goes idle, one click to restore the window)
- [ ] Inno Setup / winget package
- [ ] Code signing (removes the SmartScreen warning)

## Links

- Official repo: [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) (MIT, Discussions open)
- Official npm package: [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)
- Curated plugin list: [awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin)
- Other community desktop shells: [RAFOLIE/dsh-desktop-windowos](https://github.com/RAFOLIE/dsh-desktop-windowos), [anywhere-labs/deepseek-harness-desktop](https://github.com/anywhere-labs/deepseek-harness-desktop), [salathleizhang/deepseek-harness-desktop](https://github.com/salathleizhang/deepseek-harness-desktop), [ChisaAlter/Deepseek-Harness-Desktop](https://github.com/ChisaAlter/Deepseek-Harness-Desktop)

## License

MIT (see [LICENSE](LICENSE))
