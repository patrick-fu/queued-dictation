# 录音与历史接口

`DictationCore.RecordingApplication` 是 App 操作和行为检查的共同入口，所有操作在 `MainActor` 上执行。AppKit 使用此入口，设备、时间、可用磁盘与钥匙串可在系统边界替换。

| 操作 | 约定 |
| --- | --- |
| `startRecording() async -> Bool` | 每次核验麦克风权限及安全保存额度。仅 `ready` 可开始；同一时刻只有一段。系统授权期间取消后，迟到授权不能重新启动采集。 |
| `finishRecording() async` | 停止设备并等待已有音频事件处理；有效音频形成历史，无音频无空条。 |
| `cancelCurrentRecording() async` | 只丢弃当前录音，不修改之前的历史。 |
| `history() throws -> [VoiceHistoryEntry]` | 返回实际已入库条目，按录音时间降序显示；清理超过 30 天的终结条目，保护 `awaitingProcessing`。 |
| `exportAudio(_:to:) throws` | 解密实际音频并写出单声道 16 位 PCM WAV；损坏音频不会生成导出文件。目的路径由用户主动选择，必须在加密数据目录以外。 |
| `cancelRecordedSegment(_:) throws` | 保留音频，将主状态标记为 `cancelled`，失效并取消本入口拥有的转写请求；后续模块停止其另行拥有的处理。 |
| `completeMainDelivery(_:) throws` | 主交付真实终结后标记为 `completed`；后续队列模块只在得到有效终态时调用。 |
| `deleteHistory(_:) throws` | 先失效并取消本入口拥有的转写请求，再删除历史；后续模块需同步失效其另行拥有的请求和回调。 |
| `checkRecordingConditions()` | App 的 250ms 定时器调用；空闲时仅权限变化通知 UI，录音时另检查墙钟时长及真实空间，触顶结束并保留已落盘部分。 |

`state` 仅描述录音：`ready`、`requestingMicrophone`、`recording(id:duration:)`。`notice` 提供操作结果；`onChange` 供 App 更新显示。后续网络处理应维护独立状态，不能用它阻塞下一段录音。

`AudioCapturing` 提供麦克风授权和 `AsyncThrowingStream<PCMChunk, Error>`。PCM 为单声道、有符号 16 位、小端样本，块内样本率固定，同一片段不能换率。设备停止须结束流；缓冲溢出或设备变化以错误结束，已有有效音频仍可入库。生产适配为 `MicrophoneCapture`，使用 `AVAudioEngine`，内存中转换和排队；没有明文音频文件。

`LocalDataKeyProviding` 只负责 32 字节本地数据密钥；`createIfMissing` 为 false 时必须拒绝创建。生产 `KeychainDataKey` 使用独立 service/account，未来服务凭据应使用另一命名空间，不能替换此密钥。

目录中 `vault.enc`、`history/<UUID>/entry.enc`、编号音频块均为认证加密。AES-GCM 的认证上下文绑定格式角色、片段 UUID 与音频块序号。`active` 保存尚未入库的加密块，用户主动取消会清除当前目录；崩溃中断恢复属于后续恢复票。本票不自动删除未知 active 数据。

新条目默认为 `awaitingProcessing`，录音身份为 UUID，`recordedAt` 是开始时间；转写尝试与产物的接线见[转写与交付接口](transcription.md)。当前尚无全局顺序号；后续队列票需要为全局顺序、发送时间窗和完整恢复状态补齐明确持久化，不能把显示排序当作 FIFO 证明。
