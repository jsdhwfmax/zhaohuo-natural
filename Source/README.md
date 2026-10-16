# 插件源码与构建

插件源码包括 `Plugin.cs`、`CharacterPolicy.cs`、`CharacterConfigurationJson.cs` 和 `CharacterSupport.cs`。安装正式 Release 包不需要编译器。v2.1 的最终发行状态见 [README](../README.md)；离线测试通过不能代替新 DLL 的实际游戏验收。

## 七角色配置

v2.1 保持原插件 GUID `local.zhaohuo.naturalportrait` 和安装目录，用共享 DLL 处理七位角色。新安装器写入 `characters.json` 的 `SchemaVersion: 2`，必须完整包含：

`player`、`tang-buyi`、`xiahou-lan`、`tang-moling`、`long-xiang`、`yu-xiaomei`、`tang-zheng`。

每项仅含 `Id` 和布尔值 `Enabled`。外观款式由安装器选择并复制到活动目录；运行时配置不扩展身份或资源白名单。

新 DLL 仍支持 `SchemaVersion: 1` 且恰好包含旧三角色的配置，其余四位保持关闭。缺配置沿用旧 player-only 行为；配置存在但格式、字段、角色数量或类型无效时，禁用全部自定义替换并记录错误。Schema 1/2 不能混写，也不能用部分新角色列表代替完整配置。

安装记录继续使用 Schema 4，运行协议从 1 升至 2。升级先验证原记录、原配置和所有受管文件，再在同一可回滚事务中更新 DLL 与配置。旧角色选择、首次安装编号和最初备份保留，新角色默认关闭，随后应用用户指定角色的选择。早期私人 Schema 1/2 安装记录不等同于运行配置版本，不自动迁移。

## 目录与匹配

赵活继续使用平铺 `Portraits`、`portrait-map.txt` 和 `portrait-layout.tsv`。NPC 使用 `Characters/<stable-id>/Portraits` 及同角色的 `portrait-layout.tsv`。没有跨角色的同名表情回退。

真实游戏 ID、对象名、允许的 Addressables 路径及原画回退名单固定在 `CharacterPolicy.cs`。角色配置不能扩大这些范围。运行时核对加载 handle 与实际 Sprite 来源；来源不明、缺图或 NPC 缺合法布局时保留原画。

唐布衣 `hand`、夏侯兰 `white`、唐默铃 `one_hand`、龙湘 `black`、虞小梅 `black/special5/special5_2` 被明确保留原画，即使目录里误放同名 PNG 也不替换。虞小梅资源 `norseblood` 保留游戏的原始拼写。师兄女版只选择不同图片，不改变游戏逻辑或人物称呼。

## 构建与测试

重新构建需要 .NET SDK、已购买并安装的受支持游戏，以及随包提供的 BepInEx 6.0.0-be.692 Mono 核心：

~~~powershell
$gamePath = Read-Host '请输入 Steam 游戏目录（包含 Mortal.exe 的文件夹）'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Source\build.ps1 -GamePath $gamePath
~~~

默认输出到仓库 `BepInEx/plugins/ZhaoHuoNatural`。编译仅引用本机游戏库，仓库不分发游戏程序集。官方依赖与来源位于 `Dependencies`。

配置使用纯托管受限 JSON 解析器，不依赖 Unity 原生序列化。当前 PS5.1 配置解析套件通过 195 项，包含旧三角色、新七角色开关组合以及非法输入；可选 `-InstalledConfiguration` 只读样本检查会增加一项。身份与资源策略套件通过 1968 项，包括 110 项禁止替换或允许替换的判定；元数据检查解析 23 个游戏成员引用。以上均为离线证据。

~~~powershell
.\Source\Tests\Test-CharacterConfiguration.ps1 -ReportPath .\parser-result.json
.\Source\Tests\Test-CharacterPolicy.ps1 -EvidenceRoot .\policy-results
~~~

`Source/Tests/Test-RuntimeMetadata.ps1` 需要 `-GamePath`、`-NewPlugin` 和 `-ReportPath`，使用固定 Mono.Cecil 读取元数据，不执行游戏程序集。

修改或重编译插件后，需要重新绑定 Catalog、安装器固定哈希、离线基线及相应测试，不能只覆盖 DLL 或借用旧报告。发布脚本核验实际文件、图片与提示词绑定、代码版本及验收证据，生成完整校验清单；`PackageReady=false` 时拒绝发行输出。开发构建的符号文件不随玩家版分发。

## 运行与验证边界

插件只在本机读取 PNG、创建纹理并替换白名单角色的 Sprite，没有网络接口、游戏数值修改或存档写入。赵活属性头像继续使用现有专用钩子，NPC 小头像与关系面板未扩展。

诊断参数 `--zhaohuo-portrait-selftest --zhaohuo-selftest-exit` 会建立独立测试组件，调用真实资源和 UI 链路并输出报告。普通 Steam 启动不会运行诊断。新 DLL 的实际结论必须绑定对应 DLL、Catalog 和已运行的外观组合；未改美术的历史证据不能冒充本版逐套实机通过。

离线兼容检查使用随包固定 Mono.Cecil 和基线，静态读取程序集与资源，不修改 IL、不获取游戏文件，也不把未知构建标记为已实机验证。检查是外部管理器主动执行的功能，不会每次启动游戏自动执行。具体范围见[适配说明](适配说明.md)。
