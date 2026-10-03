# 语音历史与独立收藏 App 接线（#31、#34）

本切片把已有保留设置、实际产物导出和独立收藏接入 AppKit 菜单与语音历史窗口。依据 [#31](https://github.com/patrick-fu/queued-dictation/issues/31)、[#34](https://github.com/patrick-fu/queued-dictation/issues/34) 和[父规格 #22](https://github.com/patrick-fu/queued-dictation/issues/22)。

## 实际入口与数据来源

菜单增加“语音历史保留设置…”和“带教收藏…”。保留设置与 `RecordingApplication` 共用一个 `HistoryRetentionSettings`，保存成功才刷新历史并执行当前保留期清理。五个选项仍为 7、30、90、365 天和永久；保存失败保留当前选择并显示固定安全原因。

历史现有音频、原始转写、润色文本改走 `exportHistoryItem` 异步路径，并增加带教结果 JSON、整条 ZIP、收藏和清空入口。按钮可用性读取 `availableHistoryExports` 的已保存产物 metadata；窗口刷新不读取完整 WAV。缺失项禁用，ZIP 只由 Core 打包真实产物。下载失败显示已知安全 enum 文案或固定文件操作提示，不显示任意异常中的正文／token。

历史收藏启用前通过 `favoriteSnapshot(for: id)` 检查实际持久化 `.card`，避免展示用的未保存反馈覆层冒充可收藏产物。点击时再次从 Core 取当前真实反馈；`noCard` 可下载其真实带教结果，但没有建议可收藏。

两处卡片窗口构建均注入 `onFavorite`。回调传递完整 `CoachCard` 到 `favoriteSnapshot(for: card)`，由 Core 校验用户选中的片段、attempt、原文、完整建议与实际输入模式，再用稳定 attempt ID 保存；不改查另一次反馈。不移走卡片、不关闭带教、不调用模型或复制录音。

收藏与主模型共用 vault 路径和独立本地数据密钥提供者。每次保存从同一 `ResourceSettings` 读取最新 `maximumLocalBytes`，并从模型读取当前 `reservedStorageBytes`。保存回调与历史收藏 action 使用 `defer` 失效模型占用缓存；收藏删除窗口新增 `storageChanged` 回调，确认删除成功或失败均执行。成功的 store `onChange` 也失效缓存，刷新当前可见收藏窗口和资源状态。回调弱引用 App／模型，`reload()` 不写 store，避免强引用循环或递归刷新。

删除单条和清空确认明确说明会停止相关处理与交付，删除历史音频、文本与带教结果，保留独立收藏和外部下载文件。清空仅处理已提交历史；当前正在采集的录音保留。历史列表刷新保留当前片段选择。详情根据条目 dispatch 的 `audioUsed` 显示实际文本／原音频带教方式，并保留真实音频依据。

## Core 契约

本切片只修改 App 层。以下公开接口来自固定 Core checkpoint `dc5ad32c9fabf83d6d208edec335373ff16edcc4`：

```swift
RecordingApplication.init(..., historyRetentionSettings: HistoryRetentionSettings? = nil)
availableHistoryExports(_ id: UUID) throws -> [HistoryExportItem]
exportHistoryItem(_ item: HistoryExportItem, for id: UUID, to: URL) async throws
exportHistoryZIP(_ id: UUID, to: URL) async throws
clearHistory() throws
favoriteSnapshot(for card: CoachCard) throws -> FavoriteFeedback
favoriteSnapshot(for id: UUID) throws -> FavoriteFeedback
```

Core 依赖链为 `7c28e86f3eb3694a5e7258af625f23e963170e97`（后台 ASR 准备）→ `4eec0df2c77b0fec5d0a4ddc7f9ee1b25e6a9b9f`（准备期间显式重试）→ `dc5ad32…`（历史／收藏 API）。本树最先误只消费 API delta，首轮 Release 编译 exit 1，缺 `asrPreparations` 和 `wavePreparation`；这是遗漏前置依赖的编译失败，不是产品行为 red，原始日志为 `app-release-build-missing-prerequisites.log`。补齐两个依赖后没有 merge 冲突；`git diff --exit-code dc5ad32c9fabf83d6d208edec335373ff16edcc4 HEAD -- Sources/DictationCore` 实际 exit 0，所有 Core 源与固定 checkpoint 完全一致。证据为 `core-checkpoint-equivalence.diff`（空）和 `core-checkpoint-files.txt`。

## 窄窗口检查

环境：macOS 26.6.2（25G83）、arm64、Apple Swift 6.2.3。起点 `347aaf83f41fee0597a20a2d31daa53fcc6718c9`；独立临时工作树 `history-favorites-app/queued-dictation` 的相邻 `scratch/` 保存 harness 与原始日志。

实际执行：

- `swift build --target DictationCore --jobs 2 --scratch-path ../scratch/swift-debug`：exit 0，`core-build.log`。
- `swiftc -swift-version 6 -parse-as-library -I ../scratch/swift-debug/arm64-apple-macosx/debug/Modules Sources/QueuedDictation/FavoritesWindowController.swift Sources/QueuedDictation/HistoryRetentionSettingsWindowController.swift ../scratch/HistoryFavoritesWindowHarness.swift ../scratch/swift-debug/arm64-apple-macosx/debug/DictationCore.build/*.o -o ../scratch/history-favorites-window-harness`：最终 exit 0，`window-harness-compile.log`。
- `python3 ../scratch/run-window-harness.py`：首次三个场景 exit 0 且完成标记存在，两个删除场景提前 exit 0 且缺少完成标记，launcher 正确返回 exit 1，`window-harness-run-attempt1.log` 保留完整结果。
- 改为显式 `NSApplication.run()` 事件循环后，只补跑 `favorite-copy-delete` 和 `favorite-delete-failure` 两个 child：均 exit 0 且完成标记齐全，`window-harness-delete-summary.log` 与对应 `run-*.log`。
- `window-harness-verified-summary.log` 汇总五个已执行 child 的原始完成记录，没有重新运行任何场景。
- `swift build -c release --jobs 2 --scratch-path ../scratch/swift-release`：在 Core 依赖补齐、全部源与 `dc5ad32…` 一致后 exit 0（14.96 秒），包括实际 `AppDelegate`、两个窗口及最终 executable 链接，`app-release-build.log`。
- `git diff --check`：exit 0。

窄窗口使用起点 `347aaf8…` 编译的 Core 模块。窗口实际依赖的 `FavoritesStore.swift` 和 `HistoryRetentionSettings.swift` 从该起点到 `dc5ad32…` 字节完全未变，`git diff --exit-code 347aaf83f41fee0597a20a2d31daa53fcc6718c9 dc5ad32c9fabf83d6d208edec335373ff16edcc4 -- Sources/DictationCore/FavoritesStore.swift Sources/DictationCore/HistoryRetentionSettings.swift` 实际 exit 0，`window-core-dependency-equivalence.diff` 为空。完整 Release 则实际编译了新 Core 与全部当前 App 源。

五个终态场景分别验证真实保存按钮与五个选项、保存失败保留草稿且不发布变更、实际收藏列表／详情／复制／删除确认、删除失败仍执行缓存失效回调、缺密钥保留密文且不请求新密钥并禁用取用。窗口按钮使用实际 `NSButton.performClick`／`NSApplication.sendAction`；复制注入合成接收闭包，不改系统剪贴板。缺密钥 provider 抛出含假正文／token 的错误，UI 只显示固定 `FavoritesError.dataKeyUnavailable` 文案。

最初 harness 编译因 fixture 缺一个 switch 结束括号 exit 1，原始 `window-harness-compile-attempt1.log` 保留。两个删除场景提前退出是 fixture 事件循环问题；编译失败与缺少完成标记均不作为产品行为 red 或成功证据。没有为 fixture 添加生产测试 hook、替代模型或改变产品实现。

## 验收范围

窗口全程 alpha 为 0，使用临时 vault 与合成文本、固定测试数据密钥，无生产凭据、用户音频、云端请求或全局事件。检查证明上述控件 action 和窗口行为，不能证明实体点击、可见布局、键盘焦点、多显示器、Space、TCC 或正式签名包。

`AppDelegate` 的生产初始化会触达实际配置、Keychain、麦克风与全局快捷键依赖，本切片没有为测试重构构造器，也没有运行该实例。菜单、历史按钮可用性和完整卡片回调接线由实际 diff 与完整 App 编译确认，运行时菜单／历史窗口及完整临时 vault 的导出／收藏独立性由集成 owner 与 Core owner 验收。没有重复既有卡片 16 场景、ZIP 算法或收藏 crypto 全套。
