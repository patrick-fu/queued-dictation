# 运行时资源与派发接线

## 主流程审查回归检查点

- 手动插入先记录处理世代和队头产物；释放润色槽位可能同步触发观察者，因此返回后重新核验退出、停止、取消和队头，再持久化不确定状态及写入目标。
- completed 历史和 awaitingManualDelivery 的手动重润色同样受未发时间窗约束。过期会保留 waitingForResume；扩大配置时间窗不解除暂停，显式恢复才续窗。已完成交付不会重放。
- 带教设置开关即时保存到同一 scheduler；App 渲染只同步 checkbox。保存其它字段使用 scheduler 当前总开关，保留 model、prompt、concurrency、timeout、corner、inputMode 草稿。

2026-10-03 在 macOS、Swift 6.2.3 执行：

| 检查 | 实际结果 | 原始日志（工作树邻接 scratch-runtime） |
|---|---|---|
| `swift test --jobs 2 --filter RuntimeResourceBehaviorTests` 修复前 | exit 1，两个测试、五组参数，重入写文档及超窗断言失败 | confirmed-core-red.log |
| `swift test --jobs 2 --filter 'RuntimeResourceBehaviorTests\|ModelPipelineBehaviorTests/currentCandidate\|ModelPipelineBehaviorTests/exitPermanently\|ModelPipelineBehaviorTests/automaticSending'` 修复后 | exit 0，实际匹配三个测试；含已有正常队头插入控制 | confirmed-core-green.log |
| 隐藏设置窗口真实 NSButton 草稿／开关探针，修复前／后 | exit 1 两断言失败 → exit 0 一个测试 | confirmed-ui-red.log / confirmed-ui-green.log |
| `git diff --check`（当时工作树） | exit 0；未覆盖冻结 commit 的 EOF gate，见下文实际 exit 2 记录 | 终端输出 |

Core 回归使用生成 PCM、127.0.0.1 HTTP 服务、AES 历史、实际 NSTextView。UI 探针源码位于 `Tests/RuntimeUIProbes/CoachSettingsSwitchTests.swift`。它通过独立临时 Swift package 编译真实 `CoachSettingsWindowController.swift` 到 `RuntimeUI` target（依赖本树 DictationCore），运行 `RuntimeUITests`；未启动生产 App、未展示窗口、未授予 TCC、未读真实密钥或音频。App 的统一 render 显式调用 `synchronizeEnabled()`；探针以 scheduler.onChange 驱动相同入口，避免重载整个表单。

该 P2 检查点不代表原生键盘、跨 App、多屏、BYOK 网络、P95 或各 GitHub 整票验收完成；本树后续资源／网络接线记录如下。

## 资源和跨 App 运行时阶段

当前唯一写目录为 `runtime-resources/queued-dictation`，起点 `aaa575984b5a29fd28baf60819601f498cb02272`。本树按授权消费资源修复 `25e0e72`、原音频带教 `5d0c97e`、provider 选择重核 `a47c20b` 和带教整数修复 `8fd204d`，分别形成 `84d4467`、`eec57a6`、`b204275`、`b279a14`。上述模块不是本阶段再次实现；本阶段相对 `6dbeeaf` 的源码接线集中在 Recorder、既有三客户端、Scheduler 和 App 入口。

### 实际行为

- App 显式传入的 ResourceSettings 是六项额度的同一 source；每次开始录音、接受 PCM、检查当前录音、预留结果和写结果均读取最新值。没有显式 source 的已有调用保留 injected RecordingLimits／QueueLimits 语义，未暗中截成 schema 下界。
- 主积压段数包含正在录音；时长、已加密音频的实际占用与单段时长取先达到的一项。降低额度拒绝新段或截当前安全前缀，保留旧历史。ResourceSettings 原模块提供默认 20／1800 秒／256 MiB、300 秒、5 GiB、24 小时及所有范围；主整数预算增加原 JSON token 的精确验证。
- ASR＋润色继续共享一个 MainRequestBudget；Scheduler 继续独立带教池。主、带教每次后续派发读取最新并发，降低不取消已有请求。排队与离线不是已发请求，不开始整体截止。
- SystemNetworkAvailability 通过 NWPathMonitor 通知路由变化，并检查系统默认路由或目标 LAN 路由；loopback 始终可用。此检查不探测 HTTP 服务是否能成功。可注入的 NetworkAvailabilityProviding 可以控制 127 HTTP 的离线／联网行为。App 的 250 ms 既有检查也重核当前未发角色和时间窗。
- Retry-After 只从 429／503 的有界响应头提取，接受整数秒与 HTTP-date。标准字段含义见 [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#name-retry-after)。本实现将范围固定为本次实际选择的服务 ID＋Base URL；同服务三个角色的未发工作等待，其他服务或用户已改变的端点不受旧范围约束。记录头信息先通过尝试身份和整体截止守护，再释放槽位；取消、删除和超时旧尝试无效，off 的取消结果不新建 cooldown。已发失败不加入 pending、不自动重试；有效的大延迟分段唤醒而不缩短放行时间。
- 三个客户端在选择服务之后、读凭据之前检查门禁；在结果容量预留和发送前持久化可能重入后，于实际 HTTP 前再检查。网络／cooldown 等待有独立状态，不冒充超期暂停。未发工作超期后保持 waitingForResume；配置扩大不会解除，显式恢复续 anchor，不改 recordedAt／recordingEndedAt、不重放 completed 主交付。
- 本地计量包含同 vault 根目录的 active、history、favorites 与相关文件，采用每个文件的实际大小／分配量，已有增量缓存继续使用，不为每块 PCM 重扫全目录。新增 `invalidateStorageUsage()` 供独立外部存储写者使用；`storageUsage()` 和 `reservedStorageBytes` 给资源 UI／后续 FavoritesStore 接线使用。调用者还应在有改变目录可能的失败后失效缓存。
- 每个实际请求预留有界结果和原子 entry 写入量。写结果按实际完整 AES entry 编码量检查；自身预留排除，其他角色预留仍占容量。音频不能消耗在途结果、1 MiB 收尾和 64 MiB 真实磁盘余量。终态／取消／未发门禁释放相应预留；持久化失败不交付／弹卡。
- App 使用 CrossAppTextDelivery，启动加载 DeliverySettings；无效文件暂停自动上屏并提供设置入口。两个保存模式随录音目标冻结，currentCursor 只在实际 FIFO 队头交付时取得输入框；菜单、设置与手动入口移除 TextEdit 专属措辞。CoachPanel 通过真实 adapter 的 currentInputScreen 获取目标屏幕，保留原 four corner／scroll／非激活窗口组件。
- 资源窗口显示实际积压、全目录、结果预留和两个池的当前用量；动态刷新只更新状态标签，不改未保存的六项输入草稿。带教设置仍只同步单一总开关，保存其余草稿不会误开启。

### 执行证据

检查环境：macOS 26.6.2（25G83），Apple Swift 6.2.3，arm64。下面命令均在本树执行；日志均在邻接 `scratch-runtime`，UI 的临时 package 和 Release 包也在同目录。

| 实际命令／检查 | exit 和结果 | 原始日志 |
|---|---|---|
| 从冻结 `6dbeeaf` `git archive` 隔离 Sources／Tests，将三个新增资源行为测试置入；`swift test --jobs 2 --no-parallel --filter 'RuntimeResourceBehaviorTests/explicitResource\|RuntimeResourceBehaviorTests/reducedRecording\|RuntimeResourceBehaviorTests/mainConcurrency' --package-path ../scratch-runtime/resource-baseline` | exit 1；3 tests，8 issues：段数配置未生效、62 秒未截到 60、高精度 fraction 舍入成 3 | resource-core-behavior-red.log |
| 发送前预留回调中切断网络：`swift test --jobs 2 --no-parallel --filter RuntimeResourceBehaviorTests/aNetworkChangeDuringResult`，最后门禁重核前 | exit 1；1 test／3 role 参数，9 issues；各角色错误地进入 inFlight 并保留槽位／预留 | preflight-network-red.log |
| 最后门禁重核后：`swift test --jobs 2 --no-parallel --filter 'RuntimeResourceBehaviorTests\|ModelPipelineBehaviorTests\|PolishBehaviorTests\|CoachBehaviorTests\|AudioCoachBehaviorTests'` | exit 0；97 tests／5 suites／2.367 秒 | runtime-final-focused.log |
| `swift test --jobs 2 --no-parallel` | exit 0；235 tests／14 suites／16.581 秒；首轮同样 235／14／16.661 秒保留 runtime-full-first.log | runtime-full.log |
| `Scripts/build-app.sh release ../scratch-runtime/release-final` | exit 0；release 编译及 ad-hoc `codesign --verify --deep --strict` 成功 | runtime-release.log |
| `swift test --jobs 2 --no-parallel --package-path ../scratch-runtime/ui-probe` | exit 0；真实隐藏 CoachSettings NSButton／所有草稿 1 test／1 suite | runtime-ui-final.log |
| `git diff b279a14..6dbeeaf --check` | exit 2；冻结检查点测试末尾额外空行，本阶段自然移除；保留失败记录，不改写 6d SHA | confirmed-checkpoint-diff-red.log |
| `git diff aaa575984b5a29fd28baf60819601f498cb02272 --check`、工作树 `git diff --check` | exit 0；不再用 clean 工作树检查替代 commitdiff，固定后的实际 commit gate 另在最终消息回报 | runtime-base-diffcheck.log / runtime-working-diffcheck.log |

首次新增资源测试存在 Swift 宏算式编译失败，记录在 resource-core-red.log；调整测试表达式后隔离基线实际 red 如上。新 DispatchBackoff 首次编译出现 Swift 6.2.3 的 SendNonSendable SIL pass signal 6，定位到计时 existential 捕获，改为显式 MainActor task 后正常构建，记录 runtime-main-build.log／runtime-main-build-fixed.log。没有更改编译参数或增加等待截止来掩盖错误。

完整检查使用 parent 已明确的 `--no-parallel` 运行测试函数，函数内部的实际主池／带教池 3／3 和乱序请求仍保持并发。本次无 wait 失败。parent 保留的旧组合并行 wait／CI 失败由独立诊断处理，本阶段不宣称解决其根因。

二十个 RuntimeResource 行为函数覆盖：原 P2 终止重入与手动续窗、六额度的实际路径、allocated audio 64 MiB 触顶、外部真实 AES 收藏及 whole vault 缓存、sparse file 1 GiB 控制、结果余量、缺配置／离线最新 key、pending-only Retry-After 三角色与作用域、cancel／stop／prepare 联网不复活、24 小时边界、带教满池过期、并发动态降低、文本／原音频同门禁，以及生成 PCM→真实 HTTP→AES→实际 CrossApp adapter／NSTextView 的两种模式与 FIFO。原音频门禁的组件行为测试使用生成 WAV provider；App 到 store.waveAudio 的实际 provider 尚未接入，按 parent 分期留到后续 history/audio 阶段。

本阶段不消费新的保留期 scalar 修复，不接 Favorites UI／ZIP／自选保留期限／#30 恢复，不启动生产 GUI、读取真实密钥或上传真实用户音频。未验证：真实 BYOK 服务、物理断网／LAN／代理路由和权限、TCC、实体键盘、跨真实 App 的 AX 焦点／剪贴板／撤销、多屏／全屏、最低 macOS、Developer ID／公证及 P95。不可把合成文档环境或 ad-hoc 签名视为这些原生验收已通过。

freeze 前向 parent 报告了一个未实证静态邻近候选，供独立 review 裁决：旧 manual repolish 已超期 waitingForResume，stop 清 job 后再主动 repolish 可能沿用旧 queueStage 的暂停资格。当前新工作已续 anchor，但复用 stage 的语义需单独验证；不将此候选记录为 confirmed 或宣称风险已关闭。

parent 另已报告独立实际 perf 反例：合法三段 300 秒／48 kHz 合成 PCM 准备中，同步泵累计阻塞约 1083–1266 ms，后续触发等待 MainActor 约 1042–1167 ms；这不是原生 P95 采样。本阶段仅冻结资源和 adapter 接线，后台准备／公平派发的最小修复由 parent 在新工作树安排为下一优先阶段，不修改 fixture／截止／额度／原生标准。
