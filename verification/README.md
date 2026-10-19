# 验证记录

## v2.2.2：1.0.6.04 兼容适配

本轮在 Steam build `26021712` / `release_1.0.6000.4` 完成新的独立验收。运行插件仍为 v2.1.0，全部 447 张 PNG 和布局保持 v2.2.1 字节。

[新构建运行总报告](runtime-build26021712/compatibility-runtime.json)记录两组实际 Steam 诊断：赵活小师弟与六位 NPC 的代表外观，共 150 张替换图；随后七角色全部原版。正常 Setup、异步与同步加载、UI 引用、重复加载缓存和非目标保护通过。恢复原有七项选择后，普通启动观测 92.4 秒通过，未带自测参数、无插件错误。见[普通启动](runtime-build26021712/normal-startup.json)及[文件保护记录](runtime-build26021712/preservation.json)。

本轮只重测列出的七款外观，其余七款与全部未变素材沿用历史证据。未加载剧情存档，不代表全剧情、全路线或全部第三方模组组合验证。

| 范围 | 证据与实际结果 |
| --- | --- |
| 新构建兼容规则 | [三基线核验](compatibility-probe-tests-build26021712.json)：27 项；[构建识别与回退路由](build26021712-validation-tests.json)：17 项。完整基线分别检查，不混用新旧资源。具体执行环境与复用边界由报告注明 |
| 静态资源 | [七角色资源映射](game-resources-build26021712/resource-graph.json)：相对 25987745 既有映射和 Sprite 内容保持；[头像引用](game-resources-build26021712/avatar-resources.json)：5 个组件与两张头像资源，比较快照为 25957922。两份均为静态审查 |
| 安装器回归 | [角色管理](character-manager-tests.json) 64 项、[回归](character-manager-regression.json) 74 项、[共享组件](character-shared-update.json) 13 项、[扩展迁移](character-expansion-tests.json) 33 项 |
| 旧版直接升级 | [v2.2.1 升级](character-compatibility-upgrade.json) 19 项：同款零写入、七项选择、首次备份、切换回滚与卸载；[旧女版修图升级](character-artwork-patch.json) 22 项：继续支持 v2.2.0 的已知旧女版完整安装 |
| 界面和最终目录 | [GUI](character-manager-gui.json)：77 个事件断言 × 2 配置，共 154 次；[最终 Catalog](character-catalog-acceptance.json)：69 项，绑定冻结目录与 447 张真实 PNG。GUI 使用隔离 mock 后端，不冒称实际安装 |

所有本轮代码报告真实重跑并绑定相应源码。64 项夹具保留测试时 Catalog 的未就绪哈希；仅 readiness 数据变化由最终目录验收单独关联，未改写成新的测试哈希。v2.2.1 同名旧报告原字节保存在 [history-v2.2.1](history-v2.2.1/)，下面的运行记录保持各自原构建与范围。

## v2.2.1：大师兄女版手部修复

本轮管理器版本为 **2.2.1**，运行插件仍为 **2.1.0**。只替换唐布衣“明艳女侠”的 15 张 PNG，其余 432 张图、运行 DLL、布局与兼容规则保持原字节。总量仍为 7 位角色、14 套自定义外观、447 张图。

实际 Steam build `25987745` / `release_1.0.6000.3`（1.0.6.03）完成女版、精修男版、原画三组资源诊断。女版 15 张替换图逐张进行游戏内显示与手部目视核对；独立手部资源继续使用原画。完成后恢复测试前的七位角色选择，普通 Steam 启动持续响应 90.7 秒，无插件错误，随后正常关闭本次测试进程。未加载剧情存档，不代表全剧情、全路线或全部第三方模组组合测试。

| 范围 | 证据 | 结果与边界 |
| --- | --- | --- |
| 本次实机与图片绑定 | [运行总报告](runtime-v2.2.1/artwork-runtime.json) | 女版、男版、原画三组通过，绑定最终 Catalog、运行 DLL 和 15 张修复图；包含普通启动与真实安装保护证据 |
| 手部与显示核对 | [静态目视记录](artwork-patch-v2.2.1-static-review.json)及运行报告引用的游戏内记录 | 15/15 通过；截图在维护者本地保存，公开报告保留哈希，不附带游戏原画/UI截图 |
| 最终发行目录 | [图片完整性](character-art-integrity.json)、[目录验收](history-v2.2.1/character-catalog-acceptance.json) | 447 图完整，69 项目录检查通过；不代替实际游戏测试 |
| 旧女版直接升级 | [同款图片升级](history-v2.2.1/character-artwork-patch.json) | 22 项通过；用已发布 v2.2.0 安装器建立隔离安装，覆盖精确旧版识别、失败回滚、中断恢复、外部修改拒绝、重复应用及卸载 |
| 安装器与界面 | [角色管理](history-v2.2.1/character-manager-tests.json)、[回归](history-v2.2.1/character-manager-regression.json)、[共享组件](history-v2.2.1/character-shared-update.json)、[扩展迁移](history-v2.2.1/character-expansion-tests.json)、[GUI](history-v2.2.1/character-manager-gui.json) | 64 + 74 + 13 + 33 + 154 项；连同升级专项共 360 次断言执行。隔离夹具与界面 mock 的范围在各报告中说明 |

最终 Catalog 的数据验收单独记录，并引用测试时的 Catalog 哈希；没有把历史报告改写成最终图片的实机测试。v2.2.0 被同名新报告替代的文件，原字节归档于 [history-v2.2.0](history-v2.2.0/)。未修改外观可沿用下面的历史证据。

## v2.2.0：1.0.6.03 适配与赵活硬汉版

本轮管理器版本为 **2.2.0**，运行插件仍为 **2.1.0**。目标游戏为 Steam build `25987745` / `release_1.0.6000.3`（1.0.6.03）。旧 400 张 PNG 与插件 DLL 保持原字节，新增硬汉版 47 张；最终目录为 7 角色、14 套自定义外观、447 张 PNG，另有 7 个独立原版选项。

**v2.2.0 当轮实机验收已通过。** `all-on`、`brother-refined`、`hardman`、`original` 四组实际游戏资源诊断覆盖 9 套代表外观，以及 7 位角色全部使用原版的模式。无自测参数的普通 Steam 启动观测 92 秒通过，主菜单确认 `release_1.0.6000.3`，随后正常菜单退出。见[本次新构建实机报告](runtime-build25987745/compatibility-runtime.json)和[选择与文件保护记录](runtime-build25987745/installation-preservation.json)。

9 套为赵活小师弟、赵活硬汉、唐布衣精修与女版，以及夏侯兰、唐默铃、龙湘、虞小梅精修和唐铮女版。其余五套赵活外观保持原字节并沿用历史美术与运行证据，本次未在新构建下逐套重测。诊断使用实际 Addressables、立绘加载与 UI 组件，未加载剧情存档，也不是全剧情、全路线游玩测试。以下离线与界面证据各自保留范围，不代替实机结果。

| 范围 | 记录与结果 | 边界 |
| --- | --- | --- |
| 当前游戏构建运行 | [实机总报告](runtime-build25987745/compatibility-runtime.json)：四组诊断、9 套外观、7 角色原版通过；[普通启动](runtime-build25987745/normal-startup.json)：92 秒通过 | 实际 Steam / Unity 组件与主菜单检查，未加载剧情存档；其余五套赵活未在本构建逐套重测 |
| 真实安装保护 | [选择与文件保护](runtime-build25987745/installation-preservation.json)：通过 | 恢复原有角色选择，首次安装编号与备份、存档、其他插件及游戏文件保持 |
| 最终素材与目录 | [图片完整性](history-v2.2.0/character-art-integrity.json)：14 套 / 447 图；[最终目录验收](history-v2.2.0/character-catalog-acceptance.json)：68 项通过 | 核对全部实际文件哈希、旧 400 图不变、角色布局、21 个选项及 306 条所需生成记录绑定；不启动游戏 |
| 角色安装器与回归 | [角色管理](history-v2.2.0/character-manager-tests.json)：64 项；[既有安装回归](history-v2.2.0/character-manager-regression.json)：74 项 | Windows PowerShell 5.1 隔离文件夹夹具，验证事务与保护；未使用真实游戏或存档 |
| 共享组件与迁移 | [共享组件更新](history-v2.2.0/character-shared-update.json)：13 项；[三角色到七角色迁移](history-v2.2.0/character-expansion-tests.json)：33 项 | 原有选择、首次备份、失败与中断恢复、外部修改拒绝 |
| v2.1.0 → v2.2.0 | [旧正式版本升级](history-v2.2.0/character-release-upgrade.json)：19 项 | 用真实旧版本安装器建立隔离安装；验证同款零写入、硬汉仅替换赵活 47 图、七角色选择与最初备份保留。不是原地实机安装 |
| GUI 事件与布局 | [GUI 测试](history-v2.2.0/character-manager-gui.json)：77 个断言 × 2 配置，共 154 次通过 | 真实 WinForms 事件，后端采用 mock；报告保留测试时的 Catalog 快照，不伪称最终素材验收 |
| 最终硬汉界面 | [真实图预览](character-manager-gui-final-art.json)：默认与 Compact 150% 目视通过 | 实际 ImageLoader / DrawToBitmap 加载最终 PNG；未使用模拟素材就绪状态。“当前使用”标记是预览示例，不读取或修改游戏安装 |
| 新旧完整兼容规则 | [双基线检查](compatibility-probe-tests-build25987745.json)：23 项通过 | 两套完整基线分别核验，均固定 395 个相关文件、23 个游戏成员引用；只读元数据检查与隔离变异测试，不执行游戏程序集 |
| 新资源与原画回退 | [资源图核对](game-resources-build25987745/resource-graph.json)、[回退策略](game-resources-build25987745/fallback-policy-tests.json)：11 项通过 | 旧允许映射和 Sprite 内容保持；虞小梅唯一新增 `doubt` 在编译白名单外，继续显示原画 |

代码测试报告绑定规范化源码哈希。最终 Catalog 补齐素材后的数据变化由 68 项目录验收单独验证：原 64 / 74 项报告及其当时的 Catalog 哈希保留，未改写成重新执行的结果。旧版本同名报告归档于 [history-v2.1](history-v2.1/)。

### v2.1.0 的真实运行与安装记录

[安装验收](character-installation.json)与[实际运行验收](character-runtime.json)来自上一轮 v2.1.0、游戏 build `25957922` 的实测，保留原始报告字节。它们记录七角色迁移、当时的代表外观与原版模式诊断、普通 Steam 启动等结果；本轮仅将其作为未变素材及旧版本的历史证据，不用它们替代上方 build `25987745` 的新实机报告。

当前和历史验证均不代表全剧情通关、所有路线或所有第三方模组组合通过，也不保证所有未来更新自动适配。

## v1.3.0 三套外观管理器

- [安装与切换专项](appearance-manager-tests.json)：PS5.1 下 98 项通过，包括生产载荷指纹、六个切换方向、旧记录识别、循环切换、失败回滚、卸载及文件保护。使用隔离夹具，不操作玩家游戏。
- [既有安装器回归](appearance-manager-regression.json)：PS5.1 下 74 项通过，覆盖纯净安装、已有 BepInEx、版本/资源拒绝、误解压接管、失败回滚与卸载保护，绑定当时的后端代码。
- [界面与 CLI 检查](appearance-manager-gui.json)：16 项真实 WinForms 事件/布局检查及 7 项隔离 CLI 进程检查通过，按钮后端采用 mock，不是实际桌面点击或游戏切换。源码指纹使用统一 UTF-8 / LF 规范，避免 Git 换行转换使报告失效。
- [141 张图片校验](manager-art-integrity.json)：独立核对三套 47 张 PNG 的解码、透明通道、非空内容及完整载荷指纹。打包过程中没有重画或修改图片。
- [实际安装副本切换](copied-manager-switch.json)：复制真实受管安装的 221 个必要文件，包含安装记录与现有备份，只调整副本内的 GamePath。这不是完整可运行游戏。在隔离副本中依次切换小师弟→自然→帅气→小师弟并重复应用，比较首次安装记录、已有备份、共享插件、游戏程序集和其他文件。原游戏仍在运行，本轮未改动原安装；报告的 CopiedActualInstallation 范围不等于原地实机操作。

三套外观继续使用同一份插件 DLL、映射、布局和兼容探针。自然版的历史运行证据见下文；[帅气版](handsome-runtime.json)和[小师弟版](xianxia-runtime.json)各自对应已冻结的图片指纹，不能互相替代。这些历史验证证明原图片与插件的加载显示，新管理器的文件事务与界面另行验证。

帅气版和小师弟版的完整运行截图在维护者本地审阅并保留，公开包不附带这些含游戏 UI 的截图；报告中 `IncludedInPublicPackage` 标明每项是否随包提供，并保留原始截图 SHA-256 便于追溯。PASS、TSV、日志和状态报告随包提供。界面预览只使用本项目生成的三套立绘。

## 自然版历史验证

以下记录来自通过 Steam 启动的实际 Unity 进程，验证立绘资源和 UI 显示链路。两个构建均使用同一份立绘插件和 47 张 PNG。

| 验证日期 | 游戏版本 | Steam build | 记录 |
| --- | --- | --- | --- |
| 2026-10-15 | `release_1.0.6000.0` | `25953419` | [初版 PASS](runtime/PASS.txt) |
| 2026-10-16 | `release_1.0.6000.2` | `25957922` | [热修复版验证说明](runtime-build25957922/README.md)、[PASS](runtime-build25957922/PASS.txt)、[版本与指纹](runtime-build25957922/compatibility.json) |

两次均为 50/50 个成人资源加载成功、47/47 张新图替换成功、属性面板 2/2 个分支通过；正常 Setup、同步与异步加载、UI 引用、缓存及非主角保护均通过。新版逐项结果中的个人目录已移除，见 [portraits.tsv](runtime-build25957922/portraits.tsv)。测试边界见[兼容性与验证](../docs/兼容性与验证.md)。这些结果不代表全剧情通关或所有模组组合验证。

该运行验证使用的插件 SHA-256：

```text
66F6D545562FDEDF2F5E0CAA1AA8609629A42556C5779DF1C45B61F93EA00095
```

`art-integrity.json` 记录 47 张 PNG 的尺寸、透明通道与 SHA-256，不包含本机文件路径。

通用安装器测试使用隔离目录与模拟游戏文件，不读取或修改玩家存档；它验证文件安装、恢复、版本拒绝与冲突处理，不模拟游戏剧情。测试脚本位于仓库 `tests`。
