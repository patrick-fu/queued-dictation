# 历史产物的 Core 接线

唯一生产目录 history-artifacts-core/queued-dictation，起点 b60b014；先通过独立 responsive-retry-fix 的 4eec0df 关闭 ready 旧身份拒绝显式新重试，消费为 d32e310。旧模型、资源和响应性工作树保持冻结。App／Panel 由另一 owner 接入口，本切片不修改其文件。

## 冻结给 App 的公开接口

RecordingApplication 的 init 末尾追加 `historyRetentionSettings: HistoryRetentionSettings? = nil`；nil 使用 vault 邻接 history-retention-settings.json，缺文件默认 30 天。其余接口保持双方确认签名：

- `availableHistoryExports(_ id: UUID) throws -> [HistoryExportItem]`
- `exportHistoryItem(_ item: HistoryExportItem, for id: UUID, to: URL) async throws`
- `exportHistoryZIP(_ id: UUID, to: URL) async throws`
- `clearHistory() throws`
- `favoriteSnapshot(for card: CoachCard) throws -> FavoriteFeedback`
- `favoriteSnapshot(for id: UUID) throws -> FavoriteFeedback`

available 仅取 AES entry 与产品资格，不解整个 WAV。异步导出取得已拥有的 key／不可变音频描述，worker 认证 WAV、复用 HistoryExporter 编码／ZIP，并写到用户选定外部目录的随机 pending 文件；取消只和最后的 rename 互斥，长解码／编码／文件写入均在 worker。删除、取消、stop 和 prepare 失效已登记的导出；父 Task 取消也取消 worker，pending 清理。vault 内没有明文临时文件。

保留期每次读取同一个注入 source；7／30／90／365／forever 生效，无效配置抛错并保留数据。main 未终结、手动 polish、任何 queued／config／network／backoff／resume／inFlight coach、未保存状态或活跃导出均受保护。main 已上屏而 coach 尚未终态不能被保留期删除。clear 只枚举已提交 history，逐项走既有 invalidate／delete；期间阻止相关新派发，保留 active 录音、独立 favorites 与外部已下载文件。

收藏快照以成功 coach 的 attemptID 为 stable favoriteID，从真实 AES raw、已生成 polished 和完整反馈取得，不复制音频、不拥有 FavoritesStore。card 入口额外严格核相同 identity、raw、完整 result 与实际 inputMode，并拒 unsaved 反馈。no_card 是可下载的真实 JSON 结果，没有可收藏.card。

## 实际证据

public capture 使用生成 PCM、32 B 合成 data key、fake 服务 key 和 127 HTTP。完成 raw／polish／coach 后逐项导出四份文件，实际 unzip CRC 检查／ditto 解包并逐字节对照；WAV PCM 等于原采集，raw 和 polished 分别保持原文／润色语义。独立 FavoritesStore 加密保存后清空源 history 并重新实例化两 store，收藏仍完整可读；clear 时当前录音仍运行。腐坏 AES chunk 不影响 metadata availability，实际导出拒绝且保留旧用户下载文件；vault 内目标拒绝。

| 命令／阶段 | 实际 exit／结果 | 邻接 scratch-history-artifacts 日志 |
|---|---|---|
| 固定 b60 的 git archive probe，`swift test --jobs 2 --no-parallel --filter HistoryArtifactsBehaviorTests` | 1，1 test／2 issues：31 天时 main delivered／coach waitingConfiguration 被旧清理删除 | history-retention-red.log |
| Core 首个 retention green，同 filter | 0，1 test／0.062 秒 | history-api-first-green.log |
| 实际产品／ZIP／收藏／保留期／取消检查，同 filter | 0，5 tests／1 suite／0.369 秒；保留期 5 参数 | history-api-products-green.log |

首次 fixture wait 拼写导致编译失败，记录 history-retention-compile-failed.log；初稿使用不存在的 PolishStatus.waitingForSlot 与 throwing 短路写法，记录 history-api-compile-failed.log；共享自有 fixture 时未同步 private 类型可见性，记录 history-products-access-compile-failed.log。纠正实际编译错误后才取得上述行为 red／green，不以编译失败代替行为反例。

本 API checkpoint 的 full／Release 将和后续原音频带教 worker 接线组合执行一次；当前不宣称整个 #31／#33／#34 native 入口验收完成。未读真实 App vault、真实密钥或用户录音，未运行 GUI／TCC／云端模型；native Fn／实体采集／多屏／BYOK 与 30 轮 P95 尚未验证。

## 显式终结与清空的独立修复

固定 dc5 的独立审查通过 public 实际 HTTP 发现三个反例，原始 3 tests／3 issues／0.209 秒 exit 1 保存在 review-history-retention-favorite/scratch/retention-favorite-probes.log：skip 撤销 polish 后仍存 waitingForConfiguration 导致保留期保护假工作；Coach 保存失败的内存 overlay 在成功取消后仍保护记录，同 vault fresh 实例却会删除；clear 的 onChange→history 同步递归 expiry 先删另一行，使外层 clear 抛 missingHistory。

隔离 history-lifecycle-fix 树只修这些事实：skip 把被撤销的 main ASR／polish 等待／在途记录置 cancelled，保留已有产物与诊断，成功持久化后只清 main overlays；成功 cancelRecordedSegment 之后才清所有角色旧 overlays，保存失败仍保留真实失败事实。Coach 独立工作不被 skip 清掉。history 使用已有 stoppingProcessing／deletingHistory 栈内事实暂缓自动 expiry，不吞任何 I/O／权限／密钥错误。

实际 `swift test --jobs 2 --no-parallel --filter 'HistoryLifecycleBehaviorTests|HistoryArtifactsBehaviorTests/aDeliveredMain'` exit 0，5 tests／2 suites／0.338 秒，日志位于该新树邻接 scratch-history-lifecycle/lifecycle-fixed-green.log。三个原公开反例分别得到 retained 0、当前和 fresh 均 0、clear error none／remaining 0／callbacks 3；真实 manual polish waitingConfiguration 与 Coach 在途仍在 31 天时保留，明确删除后才断线。无 full／Release／原生计时重复，组合最终检查留给音频阶段。
