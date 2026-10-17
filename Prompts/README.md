# 立绘生成记录

v2.2.1 管理器收录七个角色、14 套自定义外观，共 447 张立绘。v2.0 的 312 张、v2.1 新增的 88 张和 v2.2 新增的 47 张分别保留实际生成记录；v2.2.1 修正大师兄女版的 15 张手部，图片总数不变。旧记录保留为历史，不把旧请求冒充本次修图来源。

| 外观 | 生成记录 | 管理器中的最终图片 |
| --- | --- | --- |
| 自然版 | 本目录下的 `prompts-*.json` | `BepInEx/plugins/ZhaoHuoNatural/Portraits/` |
| 帅气版 | `handsome/` | `Variants/handsome/Portraits/` |
| 修仙小师弟版 | `xianxia-junior/` | `Variants/xianxia/Portraits/` |
| 白衣少侠、黑衣冷峻、成熟侠客 | `multichar/player/` | `Variants/player/{white,black,veteran}/Portraits/` |
| 大师兄精修版 | `multichar/npc/` 与 `multichar/tang-buyi/` | `Variants/tang-buyi/refined/Portraits/` |
| 夏侯兰精修版 | `multichar/npc/` 与 `multichar/xiahou-lan/` | `Variants/xiahou-lan/refined/Portraits/` |
| 原画风硬汉赵活 | `hardman/` | `Variants/player/hardman/Portraits/` |
| 唐默铃、龙湘、虞小梅精修及唐铮女版 | `expansion-v2.1/` | `Variants/{角色ID}/{refined,female}/Portraits/` |
| 大师兄女版手部修正版 | `hand-fix-v2.2.1/`；旧生成记录仍在 `expansion-v2.1/tang-buyi/female/` | `Variants/tang-buyi/female/Portraits/` |

新增图片由内置 imagegen 生成。`multichar/index.json` 将角色、外观、图片 SHA-256 与实际请求记录一一对应；`npc-history/` 保留 NPC 修图过程的请求。生成结果以原始 PNG 字节收录，未用脚本重绘、抠图或改色。游戏运行时会按对应原作画布布局缩放和定位，这不会修改发行 PNG。

`hand-fix-v2.2.1/index.json` 绑定本次 15 张最终修图及各自的实际请求。记录中的英文 `Prompt` 保留原文，只将引用和输出路径改成可移植的来源标识。`angry3` 保留两次编辑：第一张因腰侧手部多余手指被弃用，最终采用第二次去除多余手指的结果。`normal-v1.json` 是 normal 同一次调用的早期记录快照，不算第二次生成。

修图记录中的 `Revision: v2.2.0` 指替换前图片；即使路径与当前成品相同，也须结合记录里的旧 SHA-256 区分。旧 15 张和中间弃用 PNG 不随本次包分发。旧 `expansion-v2.1/index.json` 的大师兄女版条目仍绑定旧输出，作为历史保留；当前输出以 `hand-fix-v2.2.1/index.json` 为准。`SourceRecordSha256` 对应脱敏前的原始私有记录；公开包装记录本身的校验以发行包 `ReleaseManifest.json` 为准。

帅气版和小师弟版记录产生于独立外观包阶段，记录内的 `BepInEx/plugins/ZhaoHuoNatural/Portraits/` 指当时的成品目录。整合后按上表映射；图片内容和 SHA-256 未变。小师弟版 `index.json` 将 47 个资产绑定到最终采用的生成结果，未采用的修正前输出不作为成品分发。

小师弟索引的 `SourceRecords` 哈希对应本机路径规范化之前的原始生成记录，属于来源追溯值，不是发行副本文本的校验值。`Assets` 中的输出哈希对应最终 PNG；公开文本副本的精确字节校验以发行包 `ReleaseManifest.json` 为准。

小师弟版使用内置 imagegen 生成。`caught`、`eye_mask_nervous2`、`mask`、`suck4` 的实际请求曾带有无效的 `undefined` 前缀，发行记录保留 `rawPrompt`，另附仅移除此开头的 `cleanPrompt`。通用设计规范单独保留，不补写成这四次请求的实际正文。

记录中的 reference、generated-source 等路径是来源标识，不代表相应参考图片或中间稿随包分发。本机路径已在发行副本中规范化；原始游戏立绘、游戏资源及被弃用的大头修仙草稿不在此仓库中。
