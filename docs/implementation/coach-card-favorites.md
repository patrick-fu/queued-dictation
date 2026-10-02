# 带教卡片收藏入口（#34）

本切片在实际 `CoachPanelWindowController` 的每张卡片提供收藏入口，依据[父规格 #22](https://github.com/patrick-fu/queued-dictation/issues/22) 中收藏保存对应文本与建议、收藏不移走卡片的决议。App 的持久化接线由集成 owner 完成。

## 接线契约

初始化末尾新增可选参数 `onFavorite: ((CoachCard) throws -> Void)? = nil`。已有调用者可以继续使用原初始化参数；没有保存回调时不显示收藏按钮。

按钮传递点击时的完整 `CoachCard`，包括片段与带教 attempt 身份、未经润色的对应原文、全部建议与音频依据，以及本次实际 `inputMode`。调用者须先核验这些反馈已在当前历史 attempt 中持久化，再以带教 `attemptID` 作为稳定收藏 ID 创建独立 `FavoritesStore` 快照；不能仅用片段 ID 查找另一次反馈替代用户选中的结果。存储错误向回调抛出，面板显示“未能保存收藏，请重试。”，不会显示异常可能携带的正文。

正常收藏只调用保存回调，不改变卡片顺序、移走卡片或切换带教，不发送模型请求。成功显示“已收藏。”；按钮可以再次点击，存储的幂等性由稳定收藏 ID 保证。该提示表达上次保存结果，不是实时收藏成员状态。收藏不持有或复制原音频。

收藏按钮沿用不能成为 key／main window 的非激活面板，并拒绝成为 first responder。它不激活 App。单卡“看完并移走”和整窗关闭仍分别执行移走展示、持久化关闭唯一带教总开关。

## 延迟 action 与同步重入

处理前同时核验实体按钮仍属于当前窗口、当前按钮绑定及完整卡片快照；旧 attempt、已移走或关闭后的按钮失效。同一 attempt 的保存期间禁用其按钮，并拒绝已调度的重复 action，卡片重建后仍保持这个限制。

回调返回后重新核验完整快照与当前按钮。回调重入 `render()`、移走或删除卡片、关闭总开关时，不用旧按钮或旧状态恢复卡片。若回调只导致其他卡片改变而重建当前卡片，保存结果更新当前按钮；保存状态随同一快照保留，在该快照失效或整窗清空时移除。

收藏成功／失败提示位于对应卡片内，与整窗关闭设置错误分开。刷新相同卡片不会清空收藏错误，其他卡片重建也保留仍有效快照的提示；保存回调中的关闭失败不会被收藏终态覆盖。

## 实际检查

环境为 macOS 26.6.2（25G83）、arm64、Apple Swift 6.2.3。测试仅使用合成文本、1 秒合成 PCM16 WAV、fake URLProtocol 服务和不读取钥匙串的凭据实现，没有用户音频或生产密钥。

仓库永久测试 target 仅依赖 `DictationCore`，因此没有修改 `Package.swift`；独立 harness 在 worktree 相邻 `../scratch` 中编译实际面板源码。每个场景使用独立进程，除 exit 0 外必须输出对应完成标记，防止 AppKit 提前结束被误判为通过。

已实际执行并通过：

- `swift build --target DictationCore --scratch-path ../scratch/swift-debug`，exit 0。
- `swiftc -swift-version 6 -parse-as-library -I ../scratch/swift-debug/arm64-apple-macosx/debug/Modules Sources/QueuedDictation/CoachPanelWindowController.swift ../scratch/CoachCardFavoriteHarness.swift ../scratch/swift-debug/arm64-apple-macosx/debug/DictationCore.build/*.o -o ../scratch/coach-card-favorite-harness`，exit 0。
- `python3 ../scratch/run-harness.py`，16 场景各自 exit 0、完成标记齐全：文本／音频完整回调、未注入回调、保存抛错与普通刷新、重建后的错误、同卡重入、旧 attempt、移走与整窗关闭及重开、回调 remove／delete／off 各成功与抛错、关闭保存错误与收藏成功／失败同时保留。收藏操作均未增加模型请求；测试 App 未激活且没有 key window。
- `swift build -c release --scratch-path ../scratch/swift-release`，exit 0；已有 App 初始化调用同时编译通过。
- `git diff --check`，exit 0。

实现过程实际得到缺少初始化参数的编译 red，以及刷新清空保存错误、重建后丢失保存错误、重入重复保存三个行为 red；对应修正后得到 green。固定提交后的独立审查和单变量消融由集成 owner 安排。

原始证据为 `../scratch/red-compile.log`、`error-red-run.log`、`rebuild-red-run.log`、`nested-red-run.log`、`final-harness-compile.log`、`final-harness-summary.log`、各 `run-*.log` 和 `release-build.log`。harness 与执行脚本保留在同一 scratch。

## 未验证范围

窗口全程 alpha 为 0。正常按钮使用真实 `NSButton.performClick` 路由；延迟与重入 action 使用真实按钮的 target／selector 经 `NSApplication.sendAction` 路由。合成鼠标事件经 `NSApplication.sendEvent` 虽命中控件，但未产生按钮 action；这次尝试不作为通过证据。多 fixture 共用的 async AppKit 进程曾提前 exit 0，最终使用独立进程与完成标记后所有场景完整执行。

这些检查不能证明实体鼠标操作、可见布局、跨 App 输入焦点、多显示器、全屏／Space 或正式发布包。它们也不验收 App owner 的持久化反馈校验、稳定 ID 与独立收藏存储接线；这些需要在集成层核验。未修改 Core、AppDelegate、收藏窗口或存储，也未重复收藏加密测试。
