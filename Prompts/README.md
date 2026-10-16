# 立绘生成记录

v2 管理器收录六套赵活立绘与唐布衣、夏侯兰精修版，共 312 张。旧版 141 张沿用各自完成时的记录；新增 171 张单独索引，不将旧版记录写成新图片的来源。

| 外观 | 生成记录 | 管理器中的最终图片 |
| --- | --- | --- |
| 自然版 | 本目录下的 `prompts-*.json` | `BepInEx/plugins/ZhaoHuoNatural/Portraits/` |
| 帅气版 | `handsome/` | `Variants/handsome/Portraits/` |
| 修仙小师弟版 | `xianxia-junior/` | `Variants/xianxia/Portraits/` |
| 白衣少侠、黑衣冷峻、成熟侠客 | `multichar/player/` | `Variants/player/{white,black,veteran}/Portraits/` |
| 大师兄精修版 | `multichar/npc/` 与 `multichar/tang-buyi/` | `Variants/tang-buyi/refined/Portraits/` |
| 夏侯兰精修版 | `multichar/npc/` 与 `multichar/xiahou-lan/` | `Variants/xiahou-lan/refined/Portraits/` |

新增图片由内置 imagegen 生成。`multichar/index.json` 将角色、外观、图片 SHA-256 与实际请求记录一一对应；`npc-history/` 保留 NPC 修图过程的请求。生成结果以原始 PNG 字节收录，未用脚本重绘、抠图或改色。游戏运行时会按对应原作画布布局缩放和定位，这不会修改发行 PNG。

帅气版和小师弟版记录产生于独立外观包阶段，记录内的 `BepInEx/plugins/ZhaoHuoNatural/Portraits/` 指当时的成品目录。整合后按上表映射；图片内容和 SHA-256 未变。小师弟版 `index.json` 将 47 个资产绑定到最终采用的生成结果，未采用的修正前输出不作为成品分发。

小师弟索引的 `SourceRecords` 哈希对应本机路径规范化之前的原始生成记录，属于来源追溯值，不是发行副本文本的校验值。`Assets` 中的输出哈希对应最终 PNG；公开文本副本的精确字节校验以发行包 `ReleaseManifest.json` 为准。

小师弟版使用内置 imagegen 生成。`caught`、`eye_mask_nervous2`、`mask`、`suck4` 的实际请求曾带有无效的 `undefined` 前缀，发行记录保留 `rawPrompt`，另附仅移除此开头的 `cleanPrompt`。通用设计规范单独保留，不补写成这四次请求的实际正文。

记录中的 reference、generated-source 等路径是来源标识，不代表相应参考图片或中间稿随包分发。本机路径已在发行副本中规范化；原始游戏立绘、游戏资源及被弃用的大头修仙草稿不在此仓库中。
