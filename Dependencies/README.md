# 离线运行依赖与来源

本目录提供 Windows x64、Unity Mono 使用的 BepInEx `6.0.0-be.692+851521c`。文件直接取自 [BepInEx 官方构建站](https://builds.bepinex.dev/projects/bepinex_be)，没有从玩家的游戏目录复制运行库。

## 安装器接口

- `BepInEx/runtime-manifest.json` 的 `Files` 数组列出 15 个安装文件：14 个核心 DLL 和官方 `doorstop_config.ini`。
- 每项 `RelativePath` 相对于游戏根目录；对应文件位于 `BepInEx/files/<RelativePath>`，`Sha256` 用于安装前校验。
- `winhttp.dll` 由发行包的 `Loader/` 提供，为官方 UnityDoorstop `4.3.0` x64。本目录不再放置第二份加载器。
- 玩家从发行包根目录运行安装脚本即可。安装器负责区分纯净游戏与已有 BepInEx 的游戏，并保存恢复清单。

运行文件保留官方原始字节。仅省略 XML API 文档、更新记录和空目录；不存在游戏程序集、Unity 程序集、存档或旧美化包文件。`Mono.Cecil.Pdb.dll` 是运行库组件，不是调试符号文件。

## 固定版本与校验

[完整来源和 SHA256 清单](BepInEx/deps-manifest.json) 记录官方下载地址、各组件版本、源代码与许可证散列。SHA256 是本项目对下载内容计算的完整性校验值，不代表上游另行发布了签名校验文件。

- 官方发行 ZIP：[`BepInEx-Unity.Mono-win-x64-6.0.0-be.692+851521c.zip`](https://builds.bepinex.dev/projects/bepinex_be/692/BepInEx-Unity.Mono-win-x64-6.0.0-be.692%2B851521c.zip)
- ZIP SHA256：`9A3472F5EEFB35A84AE8C6DEA16814B728AFF807C67C14FBFD448E20112951A6`
- BepInEx 源码提交：[`851521cc126e4f9d841d2d9bfe857558f0395939`](https://github.com/BepInEx/BepInEx/tree/851521cc126e4f9d841d2d9bfe857558f0395939)
- Doorstop 官方发布：[`v4.3.0`](https://github.com/NeighTools/UnityDoorstop/releases/tag/v4.3.0)

官方 be.692 x64 ZIP 自带的 `winhttp.dll` 与单独发布的 Doorstop 4.3.0 x64 文件 SHA256 相同：`D3B62F4C9C3E2196EF82603C52D6B98C043A0D6C125C081FD33D7CA3798B41B8`（PE Machine `0x8664`）。发行包只保留 `Loader/` 中的一份。

2026-10-15 核对结果：这 14 个核心 DLL 的 SHA256 与《活侠传》Steam build `25953419`、游戏版本 `release_1.0.6000.0` 已通过游戏内验证的 BepInEx 核心文件全部一致。这是二进制一致性核验；实际游戏验证详情见发行包主说明。

## 许可证与源码

上游 BepInEx 发行 ZIP 没有附带许可证文本，本项目从对应上游源码或官方 NuGet 包补齐原始文本。BepInEx 的许可证是 `LGPL-2.1-only`；UnityDoorstop 4.3.0 使用 LGPLv2.1。其他依赖各自保留许可证，不能将整个依赖目录视为 MIT。

- [第三方组件说明](../THIRD_PARTY_NOTICES.md)
- [`licenses/`](licenses/)：原始许可证及嵌入组件署名。
- [`sources/BepInEx-851521cc126e4f9d841d2d9bfe857558f0395939.zip`](sources/BepInEx-851521cc126e4f9d841d2d9bfe857558f0395939.zip)：该构建对应的完整官方源码，包括构建脚本。
- [`sources/UnityDoorstop-v4.3.0.zip`](sources/UnityDoorstop-v4.3.0.zip)：对应加载器的完整官方源码，包括构建脚本。

源码归各上游项目所有，未作修改；可依据其许可证重新构建或替换相应运行库。源码归档和许可证用于再分发说明，不会由安装器复制到游戏根目录。
