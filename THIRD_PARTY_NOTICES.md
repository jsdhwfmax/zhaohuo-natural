# 第三方组件声明

本发行包包含下列未修改的开源运行组件。项目自身的许可证不改变这些组件的许可证、版权或署名。各组件随其上游许可证提供，相关免责声明以原始许可证文本为准。

| 组件 | 固定版本 | 许可证与原始声明 |
| --- | --- | --- |
| [BepInEx](https://github.com/BepInEx/BepInEx/tree/851521cc126e4f9d841d2d9bfe857558f0395939) | 6.0.0-be.692+851521c | [LGPL-2.1-only](Dependencies/licenses/BepInEx-LGPL-2.1.txt)，BepInEx Team |
| [UnityDoorstop](https://github.com/NeighTools/UnityDoorstop/releases/tag/v4.3.0) | 4.3.0，Windows x64 | [LGPLv2.1](Dependencies/licenses/UnityDoorstop-4.3.0-LICENSE.txt) |
| [HarmonyX](https://github.com/BepInEx/HarmonyX/tree/v2.10.1)（0Harmony.dll） | 2.10.1 | [MIT，BepInEx](Dependencies/licenses/HarmonyX-2.10.1-LICENSE.txt)；保留原作 [Harmony / Andreas Pardeike 的 MIT 声明](Dependencies/licenses/Harmony-original-LICENSE.txt) |
| [MonoMod.RuntimeDetour、MonoMod.Utils](https://github.com/MonoMod/MonoMod/tree/bab61c308f2dbf3a27fea1e29a6a2f200aa72830) | 22.5.1.1 | [MIT，0x0ade](Dependencies/licenses/MonoMod-22.5.1.1-LICENSE.txt) |
| [Mono.Cecil 及 Mdb、Pdb、Rocks](https://github.com/jbevain/cecil/tree/0.10.4) | 0.10.4 | [MIT，Jb Evain、Novell](Dependencies/licenses/Mono.Cecil-0.10.4-LICENSE.txt) |
| [SemanticVersioning](https://github.com/adamreeve/semver.net/tree/c52c9d4c5d34a6a3bb6ff45f7276d8b6e951a42d) | 2.0.2 | [MIT，Adam Reeve](Dependencies/licenses/SemanticVersioning-2.0.2-LICENSE.txt) |
| [AssetRipper.Primitives](https://github.com/AssetRipper/AssetRipper.Primitives/tree/2e8940973fe58184b259ba9959b1359d87fce790) | 3.1.1 | [MIT，ds5678](Dependencies/licenses/AssetRipper.Primitives-3.1.1-LICENSE.txt)；保留其中 [uTinyRipper / mafaca 的 MIT 声明](Dependencies/licenses/AssetRipper-uTinyRipper-LICENSE.txt) |

## LGPL 组件源码

与随包 BepInEx 和 UnityDoorstop 二进制相对应的完整官方源代码及构建脚本一起提供：

- [BepInEx 源码 ZIP](Dependencies/sources/BepInEx-851521cc126e4f9d841d2d9bfe857558f0395939.zip)，提交 `851521cc126e4f9d841d2d9bfe857558f0395939`。
- [UnityDoorstop 4.3.0 源码 ZIP](Dependencies/sources/UnityDoorstop-v4.3.0.zip)，提交 `d061d7eabe9fc36140e7239955515801e2b9db12`。

这些库没有被修改。可以依据相应许可证修改、重新构建和替换这些库；本项目不对为调试这类修改而进行的逆向工程附加限制。源代码归档保留上游目录、版权与构建文件。

全部下载来源、文件版本和 SHA256 见 [依赖来源清单](Dependencies/BepInEx/deps-manifest.json)。加载器位于 `Loader/winhttp.dll`，安装器使用的 BepInEx 运行文件位于 `Dependencies/BepInEx/files/`。

游戏《活侠传》、游戏程序和原版美术不包含在本发行包中，其权利属于各自权利人。
