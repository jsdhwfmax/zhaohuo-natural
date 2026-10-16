# 三套立绘的生成记录

管理器收录三套已经完成的立绘，每套 47 张。记录沿用各自完成时的文件，不将旧版记录写成新图片的来源。

| 外观 | 生成记录 | 管理器中的最终图片 |
| --- | --- | --- |
| 自然版 | 本目录下的 `prompts-*.json` | `BepInEx/plugins/ZhaoHuoNatural/Portraits/` |
| 帅气版 | `handsome/` | `Variants/handsome/Portraits/` |
| 修仙小师弟版 | `xianxia-junior/` | `Variants/xianxia/Portraits/` |

帅气版和小师弟版记录产生于独立外观包阶段，记录内的 `BepInEx/plugins/ZhaoHuoNatural/Portraits/` 指当时的成品目录。整合后按上表映射；图片内容和 SHA-256 未变。小师弟版 `index.json` 将 47 个资产绑定到最终采用的生成结果，未采用的修正前输出不作为成品分发。

小师弟索引的 `SourceRecords` 哈希对应本机路径规范化之前的原始生成记录，属于来源追溯值，不是发行副本文本的校验值。`Assets` 中的输出哈希对应最终 PNG；公开文本副本的精确字节校验以发行包 `ReleaseManifest.json` 为准。

小师弟版使用内置 imagegen 生成。`caught`、`eye_mask_nervous2`、`mask`、`suck4` 的实际请求曾带有无效的 `undefined` 前缀，发行记录保留 `rawPrompt`，另附仅移除此开头的 `cleanPrompt`。通用设计规范单独保留，不补写成这四次请求的实际正文。

记录中的 reference、generated-source 等路径是来源标识，不代表相应参考图片或中间稿随包分发。本机路径已在发行副本中规范化；原始游戏立绘、游戏资源及被弃用的大头修仙草稿不在此仓库中。
