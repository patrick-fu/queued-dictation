# 转写与交付接口

本实现对应 issue 24。`RecordingApplication` 仍是 App 操作与行为检查的共同入口；`state` 只表示麦克风采集。网络请求不会把录音状态置为忙，A 请求在途时 B 可以真实开始采集。

## 共享配置

`ServiceSettings` 保存普通 JSON 配置，`ModelConfiguration.services` 包含稳定 UUID、名称、Base URL、鉴权模式。`ModelRoleConfiguration` 单独引用服务 UUID 与模型；当前只实现 `transcription`。`transcriptionTimeout` 默认 60 秒，保存时验证 5–600 秒及有限值，无效值保留原文件。Base URL 不能含用户名、密码、查询或 fragment。`validateConfiguration` 可在保存钥匙串之前检查设置。

`ServiceCredentialStoring` 的 `key(for:)`／`saveKey(_:for:)` 是凭据系统边界。生产 `KeychainServiceCredentials` 使用 `io.github.patrick-fu.queued-dictation.model-services`、每服务 UUID account；它与 `KeychainDataKey` 的 local-data namespace 分离。设置界面从不回填已有密钥；新密钥为空则保留，另有删除操作。普通配置位于加密目录之外，不能使尚未创建的 vault 被误判为已有加密数据。

`transcriptionReadiness` 只说明配置／凭据是否齐全。实际 `/audio/transcriptions` 文件请求得到有效原文才证明此角色在该配置上可用；没有 `/models` 能力推断、兼容回退或 SDK 自动重试。配置说明数据直接去往所选服务，payload 只含本段 WAV 与模型 ID。

## RecordingApplication 操作

| 操作 | 约定 |
| --- | --- |
| `configurationChanged()` | 同次运行仅续发 `waitingForConfiguration` 且尚未发送的片段。派发读取最新服务、角色、凭据和截止；已有请求保持原尝试。失败、超时、重启未确认都不自动重发。 |
| `retryTranscription(_:) throws` | 明确的重新发送操作，新建 attempt UUID。正在请求、已有原文或主状态终结时拒绝。重启后旧目标缺失，结果转手动。 |
| `rawTranscription(_:) throws` | 只返回实际安全保存的原文；没有原文或保存失败时不能假称产物可取回。 |
| `exportRawTranscription(_:to:) throws` | 用户选择目录，写出实际 UTF-8 原文，禁止写入加密数据目录。 |
| `copyRawTranscription(_:) throws` | 用户主动复制，仅改变剪贴板，不终结主交付。 |
| `insertRawTranscriptionAtCurrentCursor(_:) throws` | 用户明确操作，由交付边界检查此刻目标。不确定写回禁止再次插入；已取消／完成片段拒绝。 |
| `confirmManuallyDelivered(_:) throws` | 用户检查该段已经粘贴后明确确认，才终结主交付。 |
| `cancelRecordedSegment(_:)`／`deleteHistory(_:)` | 先失效 attempt 并取消实际 URLSession 任务、释放捕获目标，再保存取消或删除。迟到回调不能复活历史。 |
| `stopProcessing()` | 退出时取消本机网络任务并释放目标，保留已有在途记录。新进程读取这类记录显示 `interrupted`／结果未确认，等待明确处置。 |

`VoiceHistoryEntry` 增加可选的 `transcription`、`rawTranscription`、`delivery`，旧加密条目可解码。每次派发先加密保存 `inFlight` 与 attempt／service／model，再开始实际任务。成功先安全保存原文和写前 `uncertain` 标记，再执行外部写入；写后保存终态失败不会重复交付。无法保存失败状态时，当前进程显示存储失败，原音频仍保留；没有明文结果暂存。

## 请求与有限持久化

`TranscriptionAttempt` 是 DictationCore 内部的单次通用文件请求，队列票可在此基础上调整派发入口。`RequestTiming` 是单调时间边界；生产采用系统 uptime 和可取消 sleep，整体截止从派发计时并覆盖上传、响应头、完整 body 与文本有效性判断。App 的条件检查也核验绝对截止；回调接纳同时核验 segment／attempt 身份及截止。取消传至 `URLSessionDataTask.cancel()` 和 session，不能仅取消外层等待。

响应 delegate 使用 URLSession 默认的串行 delegate queue。Content-Length 超限先拒绝；没有可靠长度时逐块在追加前限制总 body 为 1 MiB。有效文本限 256 KiB UTF-8，拒绝空白、错误协议及不可用控制字符。鉴权、配额、限流、接口不兼容、ATS、连接失败、超时和保存失败各有转写角色原因；不将服务商原始错误正文显示或记录。拒绝 HTTP 重定向，避免把本段音频／凭据改发另一个地址。

派发前按最大文本的 4 倍加 64 KiB 预留 JSON 编码和原子保存空间；保存时按实际文本同规则复核。继续使用录音基础的 1 MiB 收尾余量与 64 MiB 真实磁盘保留，不以全本地 5 GiB 额度代替真实剩余空间。结果保存失败保留音频，不上屏、不创建假下载、不自动重发。

## TextEdit 边界

`TextDelivering` 是唯一外部文本交付边界。`TextEditDelivery` 只处理当前 TextEdit 普通可写文本控件：开始时记录 AX 控件／窗口、正文 SHA-256 和选区，注册正文、选区、焦点、窗口与销毁通知，并观察应用激活。没有可用 AX 权限、属性或通知则没有可靠自动目标。焦点曾离开、用户编辑／移光标、控件关闭、当前目标不同或核验失败均转手动。

写入前再次核验目标与状态，用 AXSelectedText 直接插入选区并回读预期正文确认；错误或不可确认返回 `uncertain`，不自动重复。自动写入完全不使用剪贴板。捕获信息仅供本机守护，不能进模型 payload、普通配置或导出。

录音与手动取用入口使用不能成为 key／main 的 `.nonactivatingPanel`，以 `orderFrontRegardless()` 展示。设置和历史仍是普通 AppKit 窗口。手动取用面板要求用户自行切到 TextEdit 选定光标，不能由 App 自动切回。

## 后续接线与验收边界

Fn 模块只需调用既有 `startRecording`／`finishRecording`／`cancelCurrentRecording`，不以网络在途限制触发。后续队列票仍需统一接入全局稳定录音顺序、FIFO、共享主预算、自动发送时间窗与完整恢复清单，并处理系统插入 A 后 B 的目标状态归因；当前单段派发与安全交付不是 FIFO 验收证据。模型角色配置已经与共享服务分离，尚未实现润色或带教。

自动化检查使用合成 PCM、fake API key、真实 URLSession + URLProtocol、可控单调时钟、真实文件权限失败及 `TextDelivering` 外边界。它们不证明真实麦克风／TCC、TextEdit AX 通知和撤销／富文本、非激活窗口、BYOK 模型能力、本地服务授权／ATS或正式包通过。Mac 锁定期间未执行这些原生检查，issue 24 保持待实机验收。

原生 API 依据：[Apple AXObserver 通知](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)、[NSPanel key 行为](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)、[分块 URLSession 数据](https://developer.apple.com/documentation/foundation/fetching-website-data-into-memory)、[本地 ATS](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)、[局域网用途说明](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSLocalNetworkUsageDescription)。协议依据：[文件转写](https://developers.openai.com/api/docs/guides/speech-to-text)。
