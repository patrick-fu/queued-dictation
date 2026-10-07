# 普通下载的目的地固定与原子替换

本切片修复历史 ZIP／单项下载与收藏 TXT／JSON 的目的地检查。旧实现对尚不存在的完整文件 URL 调用 `resolvingSymlinksInPath()`，没有可靠解析已存在的父目录；历史导出还在明文暂存写入后才检查。公开历史 ZIP 场景中，用户选择的目录链接在后台准备期间改指向本 fixture 的加密目录，实际得到成功、普通 ZIP 及两个明文 pending 事件。这违反[首版规格 #22](https://github.com/patrick-fu/queued-dictation/issues/22) 的本地加密和导出边界。

## 内部接口与接线

`LocalExportFile(destination: URL, vault: URL) throws` 是历史和收藏共用的内部下载模块。每个实例用于一次 `write(_ data: Data)` 和 `commit()`；不创建目标父目录。

初始化解析已存在的父目录，核验在本地加密目录之外，再用 `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` 打开实际目录。每次明文写入前及提交前，检查目录句柄仍是实际目录、所选路径仍指向同一 device／inode，并核验真实句柄路径与当前父目录均位于 vault 外。vault 的路径检查和祖先 device／inode 检查共同覆盖路径别名。目录必须可写且可搜索。

明文仅写入该目录句柄下新建的 0600 文件：`openat` 使用 `O_EXCL | O_NOFOLLOW`。完成写入与 `fsync` 后，`renameat` 在同一目录句柄中替换最终文件；失败路径用该句柄 `unlinkat` 清理自己创建的 pending。目录链接在检查之间发生变化，也不能把写入、替换或清理重定向到另一个目录。成功前不截断或删除原目标文件。

`LocalExportError.unsafeDestination` 与 `.cannotWrite` 由调用者映射：历史分别返回 `DictationError.unsafeExportDestination` 与 `HistoryExportError.cannotWrite`；收藏分别返回 `FavoritesError.unsafeExportDestination` 与 `.storageUnavailable`。错误文案不变。来源读取、认证或快照错误保留原类型，没有吞并到下载 IO 错误。

`HistoryExportOperation` 保留原 `init()` 和 `write(_:to:vault:)`，并新增兼容的 `init(destination: URL, vault: URL) throws`。新初始化只固定父目录，不读取或编码音频；其 `write` 使用已固定目录，参数沿用原调用签名。取消锁只覆盖短的目录复核和最终替换；认证、编码、数据写入及 `fsync` 均由既有 detached worker 执行，不进入取消锁。

`FavoritesStore.exportText`／`exportJSON` 在源内容读取前固定目录，复用上述写入和提交，不改快照、加密、容量或收藏 ID。

此分支没有修改 `RecordingApplication`。集成 owner 需要把 `exportHistory` 中的 `HistoryExportOperation()` 换为 `try HistoryExportOperation(destination: destination, vault: store.directory)`，置于 `Task.detached` 之前，以保留后台准备前所选的实际目录。旧初始化仍能拒绝准备期间改向 vault，但在消费新初始化前，外部目录 A 改向另一个外部目录 B 的完整公开流程尚未验收。

旧同步 `exportAudio`、`exportRawTranscription`、`exportPolishedText` 也由该文件的唯一 owner 接线：先创建 `LocalExportFile(destination:vault:)`，读取既有源数据，调用 `write`／`commit`，仅映射上述两种内部 IO 错误。它们原有的源错误与公开接口保持。没有修改 `HistoryExporter` 的独立快照编码器。

## 实际检查

在 macOS 26.6.2（25G83）、arm64、Swift 6.2.3，工作起点 `d2f28300931b91284314f6f4420c7b6d90d141f8`：

- `swift test --scratch-path ../scratch/swift-focused --filter ExportDestinationBehaviorTests`：历史公开 ZIP control／目录改向 vault 的 red，正常目录通过；改向场景实际未抛错，目录事件记录两个明文 pending 与 `history.zip`，加密目录 bytes 比较失败。修复后同一公开场景拒绝，事件记录为空、原下载与密文保持。
- `swift test --scratch-path ../scratch/swift-focused --filter 'ExportDestinationBehaviorTests.favoritesReject'`：实际 `FavoritesStore` TXT／JSON 公开下载 red；父目录链接指向 vault、最终文件尚不存在，两种下载都成功新增明文。修复后均返回既有 `unsafeExportDestination`，没有创建目标，原密文与快照保持。
- 最终同一 focused 命令 exit 0，5 tests／8 cases 完整通过：上述历史和收藏；收藏读取 fake key 时改变所选目录的两个握手场景；正常外部别名下历史 WAV／收藏 TXT／JSON 替换；只读目录拒写并保留原三个文件；父任务取消保留旧 ZIP、无 pending。真实目录事件 source 的取消 handler 均完成并关闭句柄。

最后 focused 执行同时编译 Core、App 与测试 target，包括新初始化接口；没有重跑 Core 全套、旧 ZIP／加密矩阵、Release 或压力测试。一次中间编译因 Darwin `stat` 类型／函数导入冲突失败，改用同等的 `fstatat` 后编译通过；该编译失败没有计作行为 red。

测试使用系统临时目录中的合成 fixture、32 byte 测试密钥，以及最多 1 MiB／32.768 秒（16 kHz）的合成 PCM；没有真实麦克风、AppSupport、钥匙串、用户音频、GUI、TCC 或网络服务。历史竞态以公开导出首次悬挂后的 MainActor 事件握手、原目标尚未提交的实际检查为前提，没有靠 sleep 选择结果。收藏竞态在公开 key provider 调用中改变 fixture 链接。

原始命令和证据保留在相邻 `../scratch`：`commands.txt`、`red-history.log`、`red-favorites.log`、`green-history.log`、`green-history-favorites.log`、`final-focused.log`、`final-staged.diff` 和 diff／进程检查日志。原独立审查的报告、脚本和数据仅只读参考，没有修改。

## 限制

实际已验证的是目录链接改向 vault 的拒绝、正常外部下载、权限失败和原取消语义。新初始化的 external A→B 公开流程、旧三个同步包装接线由集成 owner 验证，不能用此分支的旧调用者测试冒称完成。

目录句柄固定的是目录对象，不能阻止用户直接把整个实际目录搬走。写入前／提交前会检查句柄实际位置，检测到位于 vault 内则拒绝；已写目录在检查之间整体搬移可能移动已有暂存文件。此模块不宣称能对抗任意外部文件系统重排。若用户撤回目录删除权限，`unlinkat` 的清理尝试也受系统权限限制。本次没有执行这两类情形，不能承诺零残留。

## 组合验收中的日期 fixture 修正

`ae2c69e` 的正常下载测试使用默认 `Date()`，对收藏 JSON 按 `.secondsSince1970` 回读后断言整个 `FavoriteFeedback` 完全相等。后续组合验收实际得到 68 tests／6 suites、exit 1，唯一失败为该完整 JSON 比较；外部文件替换、只读目录、旧字节、pending 和密文检查均通过。此前 frozen focused 的 green 不能证明这个依赖当前时间的 fixture 稳定。原组合反例日志保留在 `recovery-runtime/scratch-recovery/recovery-and-export-callers-focused.log`，没有改写。

单次定向诊断使用固定 `Date(timeIntervalSinceReferenceDate: Double(800_000_000).nextUp)`，通过真实 `FavoritesStore.exportJSON` 和独立的 Foundation 日期编码／解码比较，均仅在 `createdAt` 产生差异：参考纪元 `800000000.00000012 → 800000000`，差 `-1.1920928955078125e-07`，即一个 reference ULP；Unix double 均为 `1778307200`。原／回读 reference bits 为 `41c7d78400000001`／`41c7d78400000000`。`id`、源片段 ID、原文、润色文本及完整反馈全部相等，因此没有证据指向导出文件内容损坏。

测试仅把正常下载的收藏 fixture 改为明确可表达的整数 `Date(timeIntervalSince1970: 1_700_000_000)`。同一诊断对该整数时间的整个收藏和纯 Foundation 往返均完全相等、reference delta 0；原 whole JSON equality 和其他断言全部保留，生产日期格式与三个导出源码没有修改。

自有 `../scratch-fixture-diagnosis` 中的 `DateRoundTripDiagnosis.swift` 编译和实际运行均 exit 0，并输出 `DATE DIAGNOSIS COMPLETE`；日志逐字段记录上述失配与整数对照，不依赖反复抽样。单次 `swift test --scratch-path ../scratch-fixture-diagnosis/swift-focused --filter ExportDestinationBehaviorTests.normalExternalDownloadsReplaceFilesAndReadOnlyDirectoriesPreserveThem` 实际 exit 0，1 test／1 suite 完整通过。精确命令、raw 输出和源码冻结校验保留在该目录的 `commands.txt`、`date-round-trip.log`、`normal-download-focused.log` 和 `source-freeze.log`；没有重跑组合全量、其他导出场景或 Release。
