# 插件源码与构建

插件源码由 `Plugin.cs`、`CharacterPolicy.cs`、`CharacterConfigurationJson.cs` 和 `CharacterSupport.cs` 组成。直接安装 Release 美化包不需要编译器。

v2.0.0 保持原插件 GUID 和安装目录，增加三角色独立配置。`characters.json` 只选择 player、tang-buyi、xiahou-lan 是否启用；真实游戏 ID、对象名和资产范围固定在 `CharacterPolicy.cs`，不会由外观配置扩展。缺配置沿用旧 player-only；存在但无效的配置会禁用全部自定义替换并记录错误。NPC 图片和布局按角色目录隔离；缺图回退原画。

配置使用纯托管的受限 JSON 解析器，不依赖 Unity 原生序列化。字段必须完整、类型正确且不能重复；未知字段或角色、尾随内容和过大输入均会被拒绝。`Tests/Test-CharacterConfiguration.ps1` 覆盖安装器输出、八种角色开关组合和非法输入；可通过 `-InstalledConfiguration` 只读核对实际安装配置。[52 项解析回归记录](../verification/character-configuration-parser.json) 不等同于游戏内验收。

重新构建需要 .NET SDK、已购买并安装的受支持游戏，以及 BepInEx 6.0.0-be.692 Mono 核心。先将游戏路径保存到变量，再运行：

```powershell
$gamePath = Read-Host '请输入 Steam 游戏目录（包含 Mortal.exe 的文件夹）'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Source\build.ps1 -GamePath $gamePath
```

默认输出到仓库 `BepInEx/plugins/ZhaoHuoNatural`。编译仅引用本机游戏库，仓库不分发游戏程序集。官方 BepInEx 依赖与对应来源位于 `Dependencies`。

发布脚本会根据实际文件生成完整校验清单，并记录离线探针与基线文件的 SHA-256。修改和重编译插件后应重新建立相符基线并验证；旧包升级必须由安装器在验证现有载荷后执行事务迁移，不能手动覆盖 DLL。开发构建的符号文件不随玩家版分发。

v1.0.2 更新安装器并附带离线兼容检查工具与基线，插件版本仍为 `1.0.0`，美术与映射未变。公开 v1.0.0、v1.0.1 已正常安装且文件完整时，可直接用 v1.0.2 完整包检查或安装，返回已安装而不改写原安装记录。检查工具属于外部安装包，不会通过插件在每次启动游戏时运行。打包入口为[仓库中的 Build-Release.ps1](https://github.com/jsdhwfmax/zhaohuo-natural/blob/main/scripts/Build-Release.ps1)。

离线检查使用随包提供的 Mono.Cecil 静态读取程序集和固定基线，不执行游戏程序集，不联网获取游戏文件。它只判断是否满足保守兼容条件，不修改 IL、不生成补丁，也不将未知构建标记为已实机测试。源码与文件边界见[适配说明](适配说明.md)。

插件在本机读取 PNG、创建纹理并替换白名单角色的剧情 Sprite，没有网络接口、游戏数值修改或存档写入。玩家属性头像等独立面板仍只处理赵活，NPC 小头像和关系面板未扩展。诊断参数 `--zhaohuo-portrait-selftest --zhaohuo-selftest-exit` 会建立独立测试组件并输出截图与报告；v2 增加 NPC、精确身份负例、批量加载和缓存验证。普通 Steam 启动不会运行诊断。新 DLL 的实机结论须以对应版本的新报告为准，历史 v1.x 报告不替代新运行时验证。

适配逻辑与测试边界见 [适配说明](适配说明.md)。
