# 重启恢复的 App 入口（#30）

本切片把 [#30](https://github.com/patrick-fu/queued-dictation/issues/30) 的恢复清单接到实际 AppKit 菜单与已有语音历史窗口。遵循[父规格 #22](https://github.com/patrick-fu/queued-dictation/issues/22) 的未发手动恢复、已发显式重试、旧输入目标转手动，以及写回不确定不能重复插入的决议。

## 入口与动作

菜单常驻“重启恢复清单…”，有待恢复片段时显示数量；没有片段但有启动告警时显示“有启动提示”；读取失败单独显示并保留固定安全原因。它与普通语音历史使用同一个窗口，窗口内可切换恢复清单／全部历史。恢复清单的片段 ID、每项可用动作完全来自 `RecordingApplication.recoveryItems()`，App 不自行判定角色是否未发或已发。

`RecoveryActionsView` 是已有历史窗口内的薄操作行，只显示提示并路由用户动作，不创建新窗口或恢复引擎。它依据 Core 投影分别启用“继续未发送工作”和转写／润色／带教的显式重试；投影允许多个动作时同时显示。原历史转写、润色、继续按钮在该行出现时隐藏，避免重复入口。继续调用 `resumePendingProcessing`，三种重试分别调用 `retryTranscription`、既有 `repolish` 和 `retryCoach`。没有 `requestRepolish` 接口，也没有为编译声明替代 API。

操作行注明中断录音仅找回可靠保存部分、不保证尾部，可先下载检查；继续取最新配置并重开等待时间窗；显式重试建立所选角色的新尝试，旧请求可能已发送，已有产物保留。启动摘要使用 Core 的独立 `recoveryNotice`，常规录音／服务状态不会覆盖它。显示恢复项和刷新界面不执行继续、重试或上屏。

历史行状态同样显示 Core 投影的中断录音、未发待继续、各角色待重试及交付不确定。用户可继续下载真实已有产物、复制和独立管理收藏。恢复操作刷新时保留所选 ID；该项已终结移出恢复清单时选中下一恢复项。

旧目标后的手动取用复用历史“手动交付”面板。交付不确定改为“检查并确认交付…”入口；面板禁用插入，并且插入 action 再次检查按钮启用状态，保留现有明确“确认本段已粘贴”动作。Core 仍在每次操作检查 FIFO 队头和最新有效性。复制不确认交付、不放行队列；App 不自动恢复旧输入目标或替用户点击确认。

所有新增动作使用弱 App 引用；恢复操作行及手动面板的失败仅显示已知 enum 的固定文案，未知异常不展示任意正文／token。读取恢复清单失败不冒充“没有待恢复片段”。菜单投影刷新只在录音 ready 或用户打开历史时进行，避免录音 PCM 进度更新反复扫描 AES 历史。

## 验证与来源

工作树起点：`ad1d5485a836fb209612d07ebf14245fffc65012`。本切片独占 `AppDelegate.swift`、新增薄 `RecoveryActionsView.swift` 与本说明；未改 Core、Package、脚本、永久测试或其他窗口。原有“英语带教设置…”文案已经正确，未重复修改。

完整 Core 来源是固定提交 `d7ed85275605e27e444f19b96f642828aad0cf68`，以无冲突 cherry-pick 消费到本树 `24a378aafdb9c46a7df34fe78230f5e61eb55b56`。冻结接口为 `RecoveryItem` 的七个字段、`recoveryItems() throws -> [RecoveryItem]`、`recoveryNotice: String?`、`resumePendingProcessing(_:)`、`retryTranscription(_:)`、`repolish(_:)` 和 `retryCoach(_:)`。VoiceHistoryEntry 的 `interruptedRecording: Bool?` 用于保留真实中断标记；没有重写 Core 或伪造 stub／条件编译。

`git diff --exit-code d7ed85275605e27e444f19b96f642828aad0cf68 HEAD -- Sources/DictationCore` 实际 exit 0，全部 36 个 Core 源与冻结来源完全一致。`core-frozen-equivalence.diff` 为空，`core-frozen-files.txt` 列出全部文件；最终 `final-source-and-process.json` 记录固定 Core／App 提交、源与二进制 hash 及进程终态。本树起点已有共享下载 writer 与调用者修复；初次仅核对 d7 的 parent 时存在调用者差异，消费最终 d7 后实际差异归零，没有凭父提交关系推定字节相同。

独立 `scratch/RecoveryActionsHarness.swift` 与 `run-recovery-harness.py` 使用 alpha 为 0 的实际 AppKit 控件，通过 `NSButton.performClick` 和 `NSApplication.sendAction` 路由。两项公开路径场景从合成 PCM 和临时加密 vault 建立片段，再以 fresh `RecordingApplication` 的真实恢复投影点击继续／转写重试，检查持久化等待时间窗和缺配置暂停。其余两角色及组合安全场景使用 `@testable` 构造实际 Core 类型的投影，只验证 UI flag、按钮身份、动作路由与文案；不把这些输入冒称真实 Core 崩溃恢复结果，也不新增产品 initializer。

每个 child 必须 exit 0 且输出自己的 `HARNESS COMPLETE <scenario>`，缺少标记即失败。没有生产数据密钥、系统剪贴板、真实 AppSupport、TCC、麦克风、云端请求或全局事件；未实例化生产 `AppDelegate`。

实际环境为 macOS 26.6.2（25G83）、arm64、Apple Swift 6.2.3。唯一正式检查：

- `swift build --target DictationCore --jobs 2 --scratch-path ../scratch/swift-debug`：exit 0（11.70 秒），`core-module-build.log`。
- `swiftc -swift-version 6 -parse-as-library -I ../scratch/swift-debug/arm64-apple-macosx/debug/Modules Sources/QueuedDictation/RecoveryActionsView.swift ../scratch/RecoveryActionsHarness.swift ../scratch/swift-debug/arm64-apple-macosx/debug/DictationCore.build/*.o -o ../scratch/recovery-actions-harness`：exit 0，`recovery-harness-compile.log`。
- `python3 ../scratch/run-recovery-harness.py`：exit 0；`resume-public`、`asr-public`、`polish-ui`、`coach-ui`、`projection-safety` 五个独立 child 各 exit 0，自己的完成标记齐全，`recovery-harness-summary.log` 与五个 `run-*.log`。
- `swift build -c release --jobs 2 --scratch-path ../scratch/swift-release`：exit 0（18.92 秒），实际编译全部 Core、`AppDelegate` 和新操作行并链接 executable，`recovery-app-release-build.log`。
- `git diff --check`：exit 0。

两个公开 PCM／fresh Recorder 场景实际点击生产操作行，正确传递片段 ID，各回调一次，重开 `automaticSendingStartedAt`，落盘为 `waitingForConfiguration` 且片段仍待处理、无原文结果。没有服务配置，不进行模型请求。润色和带教 synthetic 投影分别只启用自身角色按钮并完成正确 route；组合投影验证多 flag 并存、未知假正文／token 不显示、中断音频与交付不确定提示、终止／nil 状态的延迟 action 无效。本切片没有编译失败或行为 red，没有重复旧全量、导出算法或崩溃矩阵。

## 验收边界

窄 fixture 验证真实恢复操作行的控件 route 和有限公开恢复投影消费。完整菜单／历史过滤／手动面板的 Delegate 接线以实际 diff 和完整 App 编译为证；未运行其 action，特别是实际手动确认／禁用插入尚需集成验收。不将隐藏控件检查称为实体点击、可见布局、焦点、解锁桌面或正式签名包验收。Core owner 另行验证真实请求与角色恢复、崩溃点、不确定交付和加密产物，不在这里重复整套行为测试。
