# 插件源码与构建

`Plugin.cs` 是插件完整源码。直接安装 Release 美化包不需要编译器。

重新构建需要 .NET SDK、已购买并安装的受支持游戏，以及 BepInEx 6.0.0-be.692 Mono 核心。先将游戏路径保存到变量，再运行：

```powershell
$gamePath = Read-Host '请输入 Steam 游戏目录（包含 Mortal.exe 的文件夹）'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Source\build.ps1 -GamePath $gamePath
```

默认输出到仓库 `BepInEx/plugins/ZhaoHuoNatural`。编译仅引用本机游戏库，仓库不分发游戏程序集。官方 BepInEx 依赖与对应来源位于 `Dependencies`。

发布脚本会根据实际文件生成完整校验清单。修改和重编译插件后应重新打包；安装旧包的玩家需要先卸载，再安装新包。开发构建的符号文件不随玩家版分发。

插件在本机读取 PNG、创建纹理并替换主角 Sprite，没有网络接口、游戏数值修改或存档写入。诊断参数 `--zhaohuo-portrait-selftest --zhaohuo-selftest-exit` 会建立独立测试组件并输出截图与报告；普通 Steam 启动不会运行诊断。

适配逻辑与测试边界见 [适配说明](适配说明.md)。
