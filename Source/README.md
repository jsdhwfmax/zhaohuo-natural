# 插件源码与构建

`Plugin.cs` 是插件完整源码。直接安装 Release 美化包不需要编译器。

重新构建需要 .NET SDK、已购买并安装的受支持游戏，以及 BepInEx 6.0.0-be.692 Mono 核心。先将游戏路径保存到变量，再运行：

```powershell
$gamePath = Read-Host '请输入 Steam 游戏目录（包含 Mortal.exe 的文件夹）'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Source\build.ps1 -GamePath $gamePath
```

默认输出到仓库 `BepInEx/plugins/ZhaoHuoNatural`。编译仅引用本机游戏库，仓库不分发游戏程序集。官方 BepInEx 依赖与对应来源位于 `Dependencies`。

发布脚本会根据实际文件生成完整校验清单，并从安装器读取已实机验证构建的完整指纹组写入 `VerifiedGameBuilds`，同时记录离线探针与基线文件的 SHA-256。修改和重编译插件后应重新建立相符基线并打包；若插件或资源载荷改变，已安装旧包的玩家需要按提示先卸载再安装。开发构建的符号文件不随玩家版分发。

v1.0.2 更新安装器并附带离线兼容检查工具与基线，插件版本仍为 `1.0.0`，美术与映射未变。公开 v1.0.0、v1.0.1 已正常安装且文件完整时，可直接用 v1.0.2 完整包检查或安装，返回已安装而不改写原安装记录。检查工具属于外部安装包，不会通过插件在每次启动游戏时运行。打包入口为[仓库中的 Build-Release.ps1](https://github.com/jsdhwfmax/zhaohuo-natural/blob/main/scripts/Build-Release.ps1)。

离线检查使用随包提供的 Mono.Cecil 静态读取程序集和固定基线，不执行游戏程序集，不联网获取游戏文件。它只判断是否满足保守兼容条件，不修改 IL、不生成补丁，也不将未知构建标记为已实机测试。源码与文件边界见[适配说明](适配说明.md)。

插件在本机读取 PNG、创建纹理并替换主角 Sprite，没有网络接口、游戏数值修改或存档写入。诊断参数 `--zhaohuo-portrait-selftest --zhaohuo-selftest-exit` 会建立独立测试组件并输出截图与报告；普通 Steam 启动不会运行诊断。

适配逻辑与测试边界见 [适配说明](适配说明.md)。
