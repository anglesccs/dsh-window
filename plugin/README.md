# dsh-window-community（插件）

DSH 插件：安装并启动 [dsh-window](https://github.com/anglesccs/dsh-window) 桌面应用——DeepSeek Harness 的 Windows 原生窗口（WebView2）。

- 插件激活时自动确保桌面应用就绪：缺失或版本落后时从 GitHub Releases 下载精简 zip 到 `%LOCALAPPDATA%\Programs\dsh-window\`，并在桌面创建/刷新**不带版本号**的快捷方式「DeepSeek Harness Window」；已是最新则跳过下载
- 注册 `desktop_launch` 工具：对话里说"打开桌面应用"即可安装并拉起，agent 可直接调用
- 安装/下载失败不影响 DSH 启动，错误只记录日志，下次激活或调用工具时重试
- 下载走精简版（约 256KB）；便携版（自带 Node/DSH/Git）请从 Releases 手动下载

## 安装

```sh
dsh plugin --profile web add github:anglesccs/dsh-window#path:/plugin
```

> ⚠️ **不要**执行 `dsh plugin --profile web add dsh-window`。npm 上的 `dsh-window` 是**别人的同名包**（`bbtssama/dsh-window`，Typora 风格便签），与本项目无关；按那个命令装会装错东西。本插件在 npm 上叫 `dsh-window-community`。

重启 DSH（`dsh web`）后生效。要求 Windows + Node ^22.19 或 ≥ 24。

## 配置（cordis.patch.yml）

| 字段 | 默认 | 说明 |
|---|---|---|
| autoInstall | true | 激活时自动安装/升级 |
| createShortcut | true | 创建桌面快捷方式 |
| installDir | %LOCALAPPDATA%\Programs\dsh-window | 应用安装目录 |
| shortcutName | DeepSeek Harness Window | 快捷方式名称（无版本号） |
| repoSlug | anglesccs/dsh-window | 应用 zip 的 GitHub Release 来源（默认本 fork）；改用别的仓库时覆盖 |

桌面应用本身支持两种模式（`dsh-window.config.json`）：`serverMode: "local"` 在本机拉起 DSH；`serverMode: "external"` 只连 `externalUrl` 指向的远程 DSH，不解析本地运行时、不启动也不结束任何进程。远程服务器场景下把配置文件放到 exe 同目录（`--install` 会一并复制到安装目录）。

> 插件默认从本 fork（`anglesccs/dsh-window`）的 Releases 下载；想换别的仓库，在 profile 里覆盖 `repoSlug`。

# English

DSH plugin that installs and launches [dsh-window](https://github.com/anglesccs/dsh-window) — the native Windows (WebView2) window for DeepSeek Harness.

- On activation it ensures the desktop app is ready: downloads the slim zip from GitHub Releases into `%LOCALAPPDATA%\Programs\dsh-window` when missing or outdated and creates/refreshes a version-less desktop shortcut "DeepSeek Harness Window"; up-to-date installs are left alone
- Registers the `desktop_launch` tool — say "open the desktop app" in chat and the agent installs/launches it
- A failed install never blocks DSH startup; errors are logged and retried on next activation or tool call
- Uses the slim build (~256KB); the portable bundle (Node/DSH/Git included) stays a manual download from Releases

## Install

```sh
dsh plugin --profile web add github:anglesccs/dsh-window#path:/plugin
```

> ⚠️ Do **not** run `dsh plugin --profile web add dsh-window`: the npm package `dsh-window` belongs to someone else (`bbtssama/dsh-window`, a Typora-style sticky note) and has nothing to do with this project. This plugin is published as `dsh-window-community`.

Restart DSH (`dsh web`) to activate. Requires Windows + Node ^22.19 or ≥ 24.

## Configuration

See the table above; all keys are optional with those defaults.

The desktop app itself supports `serverMode: "local"` (start DSH on this machine) and `serverMode: "external"` (only connect to `externalUrl`, never resolve/spawn/kill a local runtime). For a remote DSH host, drop `dsh-window.config.json` next to the exe — `--install` copies it into the install directory.
