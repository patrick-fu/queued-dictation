# 原音频带教的派发与准备边界

本切片修复原音频运行时的三个公开反例，遵循[父规格 #22](https://github.com/patrick-fu/queued-dictation/issues/22) 中真正派发时取最新配置、未发等待不自动重试已发请求、旧尝试／回调不能覆盖当前工作的规则。仅改动 `CoachClient`、`CoachWorkScheduler`、定向回归测试和本文档；恢复状态域与 App 接线由集成 owner 处理。

## 派发前同步回调

原音频后台准备完成后，结果存储预留／持久化回调仍可能同步更改服务、密钥、模型、提示词、输入方式、并发或截止。客户端在这些回调与门禁返回后重读实际 selection，确认它与 payload 匹配，再建立并启动唯一 HTTP 请求。

只有服务／密钥／截止等不改变 body 的配置变化时，使用最新 selection 重新持久化对应 dispatch；模型／提示词／输入方式变化时，尚未发送的旧 payload 失去派发资格。Scheduler 保留同一片段和 attempt，转回 queued 并立即启动后台重准备，准备完成事件继续派发，无需下一次无关配置事件。改为文本模式不会先发旧音频再补发文本。

公开同步 `CoachClient.start` 保留原接口，必要时重建尚未发送的 payload；原音频 provider 的结果在本次尝试中复用。`startedAt` 不因同步重入重置，后台路线保留已经消耗的准备和派发前回调时间，并沿用最新合法 timeout。离线／缺配置等既有等待规则、独立带教预算和超时终态保持原合同；这些准备调整没有自动重发已发请求。

## 准备资源与迟到结果

等待状态持久化失败后，仅移除 pending 会遗留 ready preparation，从而阻塞并发为 1 时的后续合法原音频。失败路径先核验 generation 和工作身份，再移除对应准备，取消 worker 与截止任务，避免清理已失效回调所对应的新 attempt。

同一 attempt 的暂停后显式恢复会创建新 worker，只有工作身份与 generation 仍不足以区分新旧准备。每次后台准备另有独立 `workerID`，结果观察和截止任务都核验这一身份。旧被取消 worker 的失败／成功或旧截止任务不能取消、覆盖或终结新准备。

## 恢复消费接口

`@MainActor` 的 internal 只读接口 `containsWork(for segmentID: UUID) -> Bool` 同时检查 pending、active 和 preparations（包括已准备但尚未发送的 payload）。它只报告当前内存中的实际工作，不使用留存历史的 coach identity 判断 busy，不改变工作或持久化状态。恢复 owner 可在显式带教重试前消费此接口。

## 实际检查

环境：macOS 26.6.2（25G83）、arm64、Apple Swift 6.2.3。测试从公开 `RecordingApplication` 采集合成 PCM，经真实 127.0.0.1 HTTP 收取 ASR／Coach 请求，以事件和 FIFO 结果握手；凭据和数据密钥均为测试实现，没有用户音频或生产密钥。

以 `--jobs 2 --no-parallel --scratch-path ../scratch/swift-build` 逐项先 red 后 green：

- 配置／存储预留同步重入：原公开 oracle 实际 red，1 test、7 个同因断言失败；修复后旧端点 0、新端点 1，实际最新 key／model／prompt 与纯文本 body 对应同一原文，最终 slots／reservation 为 0，exit 0。
- 等待状态保存失败：原公开 oracle 实际 red，1 test、1 issue；修复后下一段无需删除失败旧段便进入准备并派发唯一原音频 POST，实际 PCM／raw 匹配，最终 slots／reservation 为 0，exit 0。
- 暂停后立即恢复：原公开 oracle 实际 red，1 test、2 issues；修复后保持同一 identity，唯一原音频 HTTP 完成并保存成功，reservation 为 0，exit 0。样本仍是 48 kHz、14,400,000 frames、300 秒；测试专用本机端点允许 64 MiB 请求，接收完整合法 WAV／base64 JSON，没有缩小样本或放宽生产时限。

三个原审查 fixture／raw logs 只读冻结。新回归位于 `AudioRuntimeBoundaryBehaviorTests`，另含同步客户端的 body 不变／改为文本两个分支，检查最新 service/key、唯一 POST，以及回调推进到第 4 秒、最新 timeout 为 6 秒时仍在第 6 秒截止。

本切片原始命令与输出位于相邻 scratch：`red-config.log`、`green-config.log`、`red-cleanup.log`、`green-cleanup.log`、`red-pause-resume.log`、`green-pause-resume.log` 和各 `*-command.json`／`*-status.json`。没有 fixture 编译失败冒充行为 red。

相关 `AudioRuntimeBoundaryBehaviorTests|AudioCoachRuntimeBehaviorTests|AudioCoachBehaviorTests|CoachBehaviorTests` 检查的首次实际结果为 47 tests／4 suites，exit 1：新行为和其余控制通过，两个旧测试固定要求释放后恰好读取 1／2 次密钥，因派发前重读而失败。暂停／等待期间零读取断言仍通过。原失败日志 `focused-controls.log` 和端口／进程终态 `focused-controls-status.json` 保留；此结果没有被当作整体通过。集成 owner 明确授权只将这两个派发后的内部计数断言改为真实 HTTP Authorization 匹配当前 fixture 假 key；音频读取一次、暂停期间密钥／音频零读取、唯一请求和原来的 payload／模式／结果／截止断言全部保留，没有固定新的内部读取次数。

这两处授权断言调整后，同一窄命令单次重跑 47 tests／4 suites 全部通过，Swift Testing 实际 2.913 秒、exit 0。原始输出 `focused-controls-green.log`、精确命令 `focused-controls-green-command.json` 和终态 `focused-controls-green-status.json` 保留；已观察的自有 loopback 监听均结束，自有测试／编译进程为 0。`git diff --check` 通过。该测试耗时不作为原生性能或用户交付 P95 指标。

## 验证范围

本轮没有重跑 Core 全套、Release、native 性能测量或真实 BYOK。真实模型听音／建议质量、TCC、实体录音快捷键、跨 App 焦点、多显示器／Space、正式发布包与原生 P95 仍须另行验收。公开恢复重试和完整 App 集成不由本文声明完成。
