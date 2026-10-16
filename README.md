# 《活侠传》角色美化管理器 v2.1.0

在一个离线窗口里，为**赵活、唐布衣、夏侯兰、唐默铃、龙湘、虞小梅、唐铮**分别选择外观。七位角色独立搭配，也能各自恢复游戏原版。

> **v2.1 已完成本机验收。** 已在 Steam build `25957922`、`release_1.0.6000.2` 验证实际安装升级、新 DLL 的三次资源诊断和至少 90 秒普通启动；400 张替换图及来源绑定通过校验。本次新 DLL 实测范围为赵活“修仙小师弟”、六位 NPC（含唐布衣两款）及七角色原版模式，未进行全剧情或全路线测试。

[发行页与完整安装包](https://github.com/jsdhwfmax/zhaohuo-natural/releases) · [安装、切换与恢复](docs/形象管理器安装指南.md) · [v2.1 更新说明](docs/release-notes-v2.1.0.md)

正式包名称为 **`ZhaoHuoPortraitManager-v2.1.0-win-x64.zip`**。完整解压到游戏目录之外，双击 **`打开美化管理器.cmd`**。普通玩家应下载发行附件中的完整离线包；GitHub 自动生成的 Source code ZIP 是源码归档。

## 外观与数量

| 角色 | 可选自定义外观 | 替换图片 |
| --- | --- | ---: |
| 赵活 | 自然版、帅气版、修仙小师弟、白衣少侠、黑衣冷峻、成熟侠客 | 6 × 47 |
| 唐布衣（大师兄） | 精修版、明艳女侠（师兄女版） | 2 × 15 |
| 夏侯兰 | 精修版 | 15 |
| 唐默铃 | 精修版 | 15 |
| 龙湘 | 精修版 | 21 |
| 虞小梅 | 精修版 | 25 |
| 唐铮（二师兄） | 冷艳女侠（师兄女版） | 12 |

完整版本为 **13 套自定义外观、7 个游戏原版选项，共 400 张替换图**。原有 312 张图片保持原字节，新增五套共 88 张；每套分别绘制表情与动作。两套师兄女版只改变立绘，**不修改剧情性别、人物称呼、对白或关系**。

| 赵活自然版 | 帅气版 | 修仙小师弟 |
| --- | --- | --- |
| <img src="BepInEx/plugins/ZhaoHuoNatural/Portraits/normal.png" width="220" alt="自然版"> | <img src="Variants/handsome/Portraits/normal.png" width="220" alt="帅气版"> | <img src="Variants/xianxia/Portraits/normal.png" width="220" alt="修仙小师弟"> |

| 白衣少侠 | 黑衣冷峻 | 成熟侠客 |
| --- | --- | --- |
| <img src="Variants/player/white/Portraits/normal.png" width="220" alt="白衣少侠"> | <img src="Variants/player/black/Portraits/normal.png" width="220" alt="黑衣冷峻"> | <img src="Variants/player/veteran/Portraits/normal.png" width="220" alt="成熟侠客"> |

## 本次新增立绘

| 唐默铃 | 龙湘 | 虞小梅 |
| --- | --- | --- |
| <img src="Variants/tang-moling/refined/Portraits/normal.png" width="220" alt="唐默铃精修版"> | <img src="Variants/long-xiang/refined/Portraits/normal.png" width="220" alt="龙湘精修版"> | <img src="Variants/yu-xiaomei/refined/Portraits/normal.png" width="220" alt="虞小梅精修版"> |

| 唐布衣·明艳女侠 | 唐铮·冷艳女侠 |
| --- | --- |
| <img src="Variants/tang-buyi/female/Portraits/normal.png" width="260" alt="唐布衣成年女侠版"> | <img src="Variants/tang-zheng/female/Portraits/normal.png" width="260" alt="唐铮成年女侠版"> |

## 使用与升级

1. 保存进度并退出游戏，打开管理器，确认包含 `Mortal.exe` 的 Steam 游戏目录。
2. 左侧选角色，右侧选外观。选择卡片只改变预览。
3. 点击“仅检查”，通过后点击“应用当前角色”。需要改变其他角色时分别选择并应用。
4. 从 Steam 库正常启动游戏。

有完整安装记录、受管文件和首次备份的旧版，可由新管理器直接升级：包括安装器正常安装的自然版、帅气版、小师弟版、v1.3 管理器，以及 v2.0 本地包。新版本核验来源后保留首次安装编号、原始备份与原有角色选择；v2.0 升级时，新加入的四位角色默认游戏原版，本次应用的目标角色按所选外观设置。

升级后统一使用 v2.1 管理器。早期私人格式、手工复制、接管过的手工包、未知文件或损坏记录不自动迁移，请按提示保留备份并恢复。具体条件见[安装指南](docs/形象管理器安装指南.md)。

选择某位角色的“游戏原版”只停用该角色。点击“全部卸载并恢复”才会恢复整个模组首次安装前的状态。

## 覆盖与兼容

- Windows x64、Steam 版《活侠传》。完整包离线附带官方 BepInEx `6.0.0-be.692` 和 x64 Doorstop；已有匹配核心与配置会保留。
- 替换已核验身份和资源的成人剧情立绘。角色身份与资源路径同时匹配，同名 `normal.png` 不会跨角色混用。
- 保留原画：赵活三张背影/剪影；唐布衣手部图；夏侯兰白色剪影；唐默铃单独手部图；龙湘黑色剪影；虞小梅黑色剪影及两张含赵活的合绘。唐铮本套十二张均提供替换。
- 独立幼年、魂等未纳入身份白名单的分支，以及 NPC 社交小头像、战斗小人、剧情 CG 不在本期范围内。缺图或缺合法 NPC 布局时回退原画。
- 更新游戏后，可用完整包重新“仅检查”。部分兼容更新能通过离线接口和资源检查；关键逻辑或资源变化仍需适配。**不保证所有未来更新通用，也不会在游戏启动时自动检查。**
- 不覆盖原游戏程序集或资源包，不修改存档、剧情和台词。剧情里的外貌评价仍然保留。

## 验证与源码

Windows PowerShell 5.1 的安装器、协议迁移、共享 DLL 回滚与界面检查通过；配置解析、身份策略和离线兼容检查另有独立记录。这些隔离或只读结果与[实际安装验收](verification/character-installation.json)、[新 DLL 游戏诊断及普通启动](verification/character-runtime.json)分别记录，不混用验证范围。

本次实际运行包含三组诊断、八套代表外观：赵活修仙小师弟、六位 NPC 及唐布衣另一款；另验证七角色全部停用和普通 Steam 启动。其余五套赵活图片保持原字节，只沿用历史美术证据，**不声称六套赵活均由 v2.1 新 DLL 重跑**。资源诊断、看图和普通启动不代表全剧情通关；未来仅部分兼容更新可通过离线检查。

[Source](Source/) 保存插件源码，[Prompts](Prompts/) 保存 builtin imagegen / gpt-image 绘图记录。只分发本项目替换图和必要依赖，不附带原游戏资源、程序集或存档。项目免费、非官方，不代表游戏原画作者的新作或官方背书。

反馈请[提交问题](https://github.com/jsdhwfmax/zhaohuo-natural/issues/new/choose)，说明游戏版本、角色、外观和复现步骤；日志先去除账号和个人路径。代码与文档见 [MIT License](LICENSE)，美术见[来源与使用说明](ARTWORK-NOTICE.md)，依赖见[第三方声明](THIRD_PARTY_NOTICES.md)。
