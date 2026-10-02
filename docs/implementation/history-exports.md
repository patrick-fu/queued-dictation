# 实际产物导出与历史保留设置

此切片为 [#31](https://github.com/patrick-fu/queued-dictation/issues/31) 提供独立的导出模块、保留设置和设置窗口。权威范围来自 [Spec #22](https://github.com/patrick-fu/queued-dictation/issues/22) 的历史、收藏、导出和隐私规则。

## 接线约定

调用者从加密历史读取已有产物，构建 `HistoryExportSnapshot(audio:rawTranscription:polishedText:coachResult:)`。不存在的产物传 `nil`；原始音频传现有 `waveAudio` 的完整 WAV，带教只传保存的 `CoachWorkUpdate.result`，不传 dispatch、完整提示词、服务配置、凭据或错误响应正文。

`HistoryExporter.availableItems(in:)` 返回实际可用项；空音频和空文本不构成可导出产物。`export(_:from:to:)` 下载单项，`exportZIP(_:to:)` 打包同一片段现有各项。缺项抛 `unavailableItem`，没有任何产物抛 `noProducts`，均不生成空文件。已保存的 `.noCard` 是实际带教结果，导出为 `{"kind":"no_card"}`；没有结果不会推断无卡。卡片 JSON 只含 `kind` 和实际 `suggestions`。

| 产物 | 固定文件名 | 格式 |
| --- | --- | --- |
| 原始音频 | `original.wav` | 完整原始 WAV 字节 |
| 原始转写 | `transcription.txt` | UTF-8，保留原始换行和 Unicode 字节 |
| 润色文本 | `polished.txt` | UTF-8，保留原始换行和 Unicode 字节 |
| 带教结果 | `coach.json` | 与带教结果契约一致的 JSON |

调用者必须在导出前执行现有 `requireSafeExport`，防止覆盖本地加密数据。导出模块不另建 vault，也不把目标路径、口述或配置写入日志。数据和 ZIP 字节在内存中生成，最后使用 Foundation 的原子写入保存到用户选择的普通文件；没有为组装 ZIP 创建音频、文本或 JSON 的临时明文副本。原子写入失败会抛 `cannotWrite`，原目标保留。

ZIP 使用 [PKWARE APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) 的 Stored 方法、CRC32、局部文件头、中央目录和单一结束记录。归档只有固定 ASCII 文件名，使用导出时的 DOS 日期，条目权限为 0600。首版不生成 ZIP64；任何需要 ZIP64 哨兵或超过普通归档尺寸的布局，在写目标前抛 `archiveTooLarge`，不截断内容。该格式上限没有降低现有 192 kHz、单段最多 3600 秒的合法 WAV 导出范围。单项下载仍可独立使用。

`HistoryRetentionSettings(file:)` 的 `load()` 和 `save(_:)` 读写单一数字 JSON。缺文件默认 `.days30`；`HistoryRetentionPeriod` 的 `.days7`、`.days30`、`.days90`、`.days365`、`.forever` 分别保存 7、30、90、365、0。其他数值、损坏 JSON、读取权限失败会明确报错，原文件不被默认值替换。保存前确认受管父目录为实际目录，且 owner 已有完整读写执行权限，再将新建或已有的可写目录收紧为 0700；0500、0000 等既有只读限制不会被解除。配置文件为 0600；在同目录的暂存配置完成写入和权限设置后原子替换，失败清理暂存并保留先前配置。

读取保留配置时，在系统 decoder 验证 JSON 和类型后，复用 `ExactIntegerJSONFields.isRootInteger(in:)` 核验源码数字。`30.0000000000000001` 和超出 Decimal 精度的 `7.000…001` 不能因解码舍入而生效；`7.0`、`3e1`、全零小数尾数和数学零仍可读。共享 object 字段检查沿用原整数算法和字段扫描；根数字支持短 UTF-8／UTF-16 源，BOM 只在内存扫描前移除，不改原文件字节。全零尾数不依赖指数机器范围，保留系统 decoder 已接纳的合法零。保存仍输出原单个数字格式。

`period.shouldExpire(recordedAt:now:isTerminal:hasActiveRequest:)` 只判断时间到期：非永久、已终结、没有活跃请求且已满所选天数时才返回 `true`。未来时间和未终结片段不会到期。调用者负责根据全部主流程、润色与带教状态计算终态和活跃工作，负责实际删除、取消和迟到结果有效性检查。永久只关闭按时间清理，不改变 `RecordingApplication` 的本地空间额度。

`HistoryRetentionSettingsWindowController` 显示五个保留选项，重新显示时读取有效配置；保存成功后才调用 `configurationChanged`，失败显示明确原因。窗口和模块已编译，菜单入口与实际历史操作由核心 owner 接线。

## 实际检查

2026-10-03，在 macOS 26.6.2、Apple Silicon、Swift 6.2.3 执行：

- `swift test --filter HistoryExportBehaviorTests`：9 项通过。测试先经历导出及保留接口缺失的预期失败，再实现；独立解压器读取实际录音生成的 WAV、混合 Unicode 文本及校验过的带教结果。
- `swift test`：131 项、8 个 suite 全通过。
- 系统 `unzip -t`、`ditto -x -k` 和 Python `zipfile`：全四项归档可打开，CRC 和解压后逐字节一致；Python `wave` 确认单声道、16 bit、16 kHz、6 帧，以及正负 PCM 边界样本。15 种非空产物组合全部验证，音频单项、原文单项及真实无卡结果均能取回。
- 缺项、空快照、目标目录不可写：明确失败，不生成缺项文件，不替换已有目标，目录中无残留明文暂存文件。
- 只读匿名虚拟内存映射提供普通 ZIP 不能表示的尺寸，验证字段及归档总尺寸都在读取内容或写目标前拒绝，原目标保留；不分配或遍历 4 GiB 实体音频。
- 保留设置：五个值保存并重新加载，目录／文件权限为 0700／0600；无效数值、损坏文件和读取失败均拒绝，保存失败保留原有效值。各期限边界、未来时间、未终结片段、活跃请求和永久均通过纯判断检查。
- `bash Scripts/build-app.sh release <临时输出目录>` 与 `bash Scripts/verify-app.sh development <App>`：release 构建及开发签名包检查通过，arm64、macOS 14.0 最低部署版本和严格签名检查通过。

保留的独立产物验收另生成真实 AES `entry.enc` 历史，并输出全项、仅音频及仅原文 ZIP。验收脚本以系统解压器和 Python 检查完整字节、限定的带教 JSON 字段、加密历史标记及保留设置权限，不依赖应用自己的 ZIP reader。测试使用公开合成样本，不访问生产凭据或用户音频。

独立审查确认旧版成功保存到已有 0755 目录后仍保留 0755，未兑现目录 0700 的约定。公开回归先在旧实现上因目录权限断言失败，再通过上述保存前核验与权限收紧修复。增量 focused 检查覆盖新目录、已有 0755、已有 0500／0000 和目标 `UF_IMMUTABLE` 导致的替换失败：成功后的目录／文件权限为 0700／0600，拒写目录权限保持，失败后的原配置字节、重新读取的有效值和目录无暂存残留均通过。此次仅重跑 6 项保留行为检查及 `swift build -c release --arch arm64 --jobs 2`，均 exit 0；之前的 131 项全量结果属于前一提交，本权限修复没有重跑全量或性能检查。

源码整数修复另以公开 `load()` 完成 red → green：原先两条非整数源被接纳为 30／7，修复后报 `invalidPeriod` 且原字节保持。`swift test --filter 'RetentionSourceBehaviorTests|ResourceSettingsBehaviorTests.(rawFractionalCounts|escapedRootInteger|wholeScientific)'` 的 9 项／2 个 suite 通过，包含共享 Coach／Resource object 入口、合法数字、六种系统已支持编码、BOM、无效字节和大指数数学零；原公开 probe 重新编译、执行后两条非法源拒绝，`7.0`／`3e1` 接纳，均无文件改写。此增量仅执行 focused 检查及 release 编译，未重跑全量、ZIP、性能或原生设置／运行入口验收。

此切片尚未完成 #31 的历史列表、删除／清空、到期调度、取消与迟到回调竞态或收藏独立性接线；这些属于后续核心集成。保留窗口的实际点击／回调、原生保存面板、真实麦克风和权限、最低系统、Developer ID 签名公证首启均未验收，不能以本次自动化和开发签名包结果替代。多视角独立 review 与有意义的消融由主 agent 在固定提交上开展。
