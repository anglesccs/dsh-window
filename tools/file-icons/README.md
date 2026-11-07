# Office 家族文件图标（无 Office 也不白页）

给一台**没装 Office** 的 Windows 11 机器补上 `.doc/.docx/.xls/.xlsx/.ppt/.pptx` 等
22 个 Office 扩展名的图标：Word 蓝、Excel 绿、PowerPoint 橙红。

两件事分开做：

- `generate-icons.ps1` 生成三个多尺寸 `.ico`（16/32/48/256，全 PNG 帧）。
- `install-file-icons.ps1` 把这些 ico 按**用户级**注册表（`HKCU\Software\Classes`，
  不需要管理员）挂到 22 个扩展名上，并保住「打开方式」选择器。

## 用法

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\file-icons\generate-icons.ps1 -Force
powershell -ExecutionPolicy Bypass -File .\tools\file-icons\install-file-icons.ps1
```

卸载（用最近一次备份还原）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\file-icons\install-file-icons.ps1 -Uninstall
```

两个脚本都有 `-IconDir <dir>`，默认是脚本所在目录。

## 生成器

- 纯 PowerShell 5.1 + .NET Framework `System.Drawing`，不联网、不用 ImageMagick。
- 圆角方块底 + 白色大写字母（W / X / P），先在 512px 级画布上画再降采样，
  16×16 也能认出来。
- ICO 容器手写：6 字节 `ICONDIR` + 每帧 16 字节 `ICONDIRENTRY` + 帧数据；
  帧是 PNG，256 帧的宽高字节写 `0`。
- 幂等：无 `-Force` 且文件已存在就跳过；结束打印每个文件字节数。

## 安装器

只写 `HKCU\Software\Classes`，绝不碰 `HKCR`/`HKLM`。

1. **先备份**：每个扩展名改前的状态（扩展名默认值、`UserChoice` 的 ProgId、
   即将创建的 ProgID 及其 `DefaultIcon` 是否已存在）写到
   `%LOCALAPPDATA%\DshFileIcons\backup-<yyyyMMdd-HHmmss>.json`。
2. **建三个 ProgID**：`DshDocFile` / `DshXlsFile` / `DshPptFile`，各自
   `DefaultIcon` 指向本地 ico，默认值是「Word 文档（无 Office）」这类可读名，
   `shell\open\command` 走 `OpenWith.exe "%1"`，`PerceivedType=document`。
3. **22 个扩展名**：
   - 没有 `Explorer\FileExts\<ext>\UserChoice` → 改 `HKCU\Software\Classes\<ext>` 默认值；
   - 有 `UserChoice` → **不动**扩展名默认值，改写那个 ProgId 的 `DefaultIcon`
     （`UserChoice` 本身不碰，Windows 10/11 也会拒绝第三方改它）。
4. `SHChangeNotify(SHCNE_ASSOCCHANGED)` 刷图标缓存。
5. 打印每个扩展名「改前 → 改后」和汇总条数。

扩展名清单是**一张表**（`$ExtensionMap`，22 条），安装和卸载都只读这张表。

### 为什么走 `OpenWith.exe`

这台机器没有 Office，双击 `.docx` 不该弹「找不到应用」的报错。把 ProgID 的打开命令
指向 `%SystemRoot%\system32\OpenWith.exe "%1"`，双击就弹系统的「打开方式」选择器，
用户可以自己挑编辑器（WPS、LibreOffice、记事本都行）。

### UserChoice 的坑

`HKCU\...\Explorer\FileExts\<ext>\UserChoice` 带 `Hash` 保护，任何脚本直接改 ProgId
都会被系统判定无效并回退。所以有 `UserChoice` 时只改它指向的 ProgID 的 `DefaultIcon`，
这是能生效、也不破坏用户已选默认应用的做法。

### 为什么会因为路径空格失效

`DefaultIcon` 的值格式是 `<路径>,<索引>`，**路径含空格时必须加引号**：

```text
DefaultIcon = "D:\DSH Script\icons\doc.ico",0     ← 生效
DefaultIcon = D:\DSH Script\icons\doc.ico,0       ← Shell 解析失败，仍是通用灰图标
```

宿主机实测：同一台机器、同一份 ico，只差一对引号，结果就是「蓝色 doc / 绿色 xls /
橙色 ppt」和「一片通用灰图标」的区别。原因是逗号既当分隔符又可能出现在路径里，
Shell 只认「引号包起来的路径 + `,` + 索引」这一种写法；不加引号时它会在第一个空格
（或逗号）处切错，取不到图标文件就静默回退。

所以安装器**无条件加引号**（`Format-IconValue`），路径里若混进 `"` 先剔掉兜底。
备份和还原仍按原字符串原样记录、原样写回，不给还原值加引号——否则会把用户原本
正确的值改坏。

验证命令（编排方验收脚本 `ci\accept_file_icons.ps1` 已覆盖，含路径空格回归）：

```powershell
# 取 Shell 实际渲染的图标，比色：doc 应接近 rgb(47,113,194)，xls rgb(34,135,83)，
# ppt rgb(216,98,66)，且必须明显偏离「通用图标」基准色。
.\ci\accept_file_icons.ps1 -IconDir "$env:RUNNER_TEMP\dsh icons" `
    -InstallScript .\tools\file-icons\install-file-icons.ps1
```

`SHGetFileInfo` 拿 `SHGFI_ICON` 渲染出的位图求不透明像素均值，再和未注册扩展名的
通用图标比色差；差得不够就判 FAIL。这条路子不看注册表文本，路径写错（比如漏引号）
会立刻变红。

## 验证

CI（`.github/workflows/accept.yml`，windows-latest）里跑：

```powershell
.\tools\file-icons\generate-icons.ps1 -Force
.\ci\accept_file_icons.ps1 -IconDir "$PWD\tools\file-icons" -InstallScript "$PWD\tools\file-icons\install-file-icons.ps1"
```

验收脚本用 `SHGetFileInfo(SHGFI_ICONLOCATION)` 逐个问 Shell「这个扩展名的图标来自
哪个文件的第几帧」，不采信安装脚本的自述；最后还会调 `-Uninstall` 并断言已恢复。
