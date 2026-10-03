# 独立带教收藏切片（#34）

本切片提供独立加密收藏、完整文本与 JSON 下载，以及主动打开的 AppKit 收藏窗口。卡片／历史中的收藏入口、主菜单及最新资源配置由主集成 owner 接线后验收；本切片不代表 [#34](https://github.com/patrick-fu/queued-dictation/issues/34) 整票完成。产品语义遵循[父规格 #22](https://github.com/patrick-fu/queued-dictation/issues/22)。

## 接线接口

- `FavoriteFeedback` 保存 `id`、`createdAt`、可选来源 `sourceSegmentID`、`rawText`、可选 `polishedText` 和完整 `CoachFeedback`。调用者只从已有合法 `.card` 建立快照；`noCard` 没有建议可收藏。来源 ID 仅便于辨认，收藏从不读取原历史的内容，也不要求来源继续存在。
- `FavoritesStore(vaultRoot:keys:maximumLocalBytes:diskSpace:reservedBytes:)` 位于 `@MainActor`。`vaultRoot` 必须与 `EncryptedHistory.directory` 相同，传入同一独立 `LocalDataKeyProviding`；API 凭据与本地数据密钥没有转换或耦合。
- `maximumLocalBytes` 每次保存读取最新额度，默认 5 GiB。`reservedBytes` 注入其他活动工作的额外预留，不能重复计入已经写在 vault 中的文件。`diskSpace` 默认读取真实可用空间，测试可独立注入。
- `save`、`entries`、`entry`、`delete`、`text`、`exportText` 和 `exportJSON` 是收藏接口。`bytesConsumed` 返回收藏目录中各文件的真实计费占用，不含历史；保存的额度检查仍扫描整个 vault。
- 每次成功保存／删除后调用 `onChange`。主集成层须在此失效历史的本地占用缓存并刷新相关界面，以免主流程沿用旧的 `knownUsage`。窗口不占用该回调；外部变动后可调用 `FavoritesWindowController.reload()`。
- 收藏移除、卡片移走、带教关闭、历史删除／到期／清空分别作用于各自内容。收藏仅由显式 `delete(favoriteID)` 删除，不置顶、不保存音频，也不延长原音频保留期。

## 存储与空间

收藏存入同一 vault 的 `favorites/<favoriteID>.enc`。沿用 `QDENC1` 标记与真实 AES.GCM，本条收藏 ID 加入 `favorite-v1` AAD；共享 `vault.enc` 使用历史已有的 `vault-v1` 契约。错误密钥、损坏标记、篡改收藏或 ID 不匹配均拒绝读取；无法解密的既有收藏不能被 `save` 静默替换。

创建密钥的条件检查整个 vault，而非只检查 favorites 是否为空。已有 history、active、favorites 或其他 vault 内容时只允许读取原密钥；缺失或不可访问时明确报错，不生成替换密钥、不改旧数据。读取空的、尚未创建的 vault 不创建密钥。

目录权限为 0700，收藏／标记文件为 0600。密文先写入受保护的临时文件，完成 fsync、真实占用和最新额度检查，再以 rename 原子替换目标；失败清理临时密文并保留旧收藏。已有目录无法写入时拒绝保存，不能通过 chmod 重新开放用户已禁止的写入。收藏存储没有明文 JSON、音频、正文临时文件或正文日志；用户主动下载的文本和 JSON 是所选位置的明文文件。

每次保存都计入整个 vault 的 history、active、favorites 和元数据文件，使用 `max(fileSize, totalFileAllocatedSize)`，不沿用收藏自己的缓存。加密临时文件的实际占用也纳入提交前检查；另留 1 MiB 加密收尾余量，以及 64 MiB 真实磁盘余量。其他活动预留同时影响本地额度和真实磁盘门槛。调低额度不删除现有收藏，也不阻止读取、下载或主动删除；超占用时拒绝新增／替换，不进行静默淘汰。

原转写与可选润色分别限 256 KiB，反馈必须已有 1–2 条建议，原表达／改进／原因分别限 8 KiB。编码后的整个快照限 4 MiB。收藏不重新调用模型或判断英语／建议质量；原表达允许为空，以保留音频流利度反馈对象。

JSON 下载完整保存上述快照字段及已有 `CoachFeedback`，`createdAt` 为 Unix 秒数，保留小数；使用 `JSONDecoder.dateDecodingStrategy = .secondsSince1970` 可读取公开类型。现有 Codable 同样保留 `audioEvidence` 的 `startSeconds`、`endSeconds`、`observation`，无需改变下载格式。UTF-8 文本包含原转写、实际存在的润色，以及每条建议的类别、原表达、改进和中文原因；实际带有音频依据的建议还包含原起止秒数与完整观察文字，秒数不做取整或固定小数截断。流利度没有原表达时省略该行。导出目的地必须在 vault 外，解析别名并比较目录身份，避免覆盖原始加密数据。

## 收藏窗口

`FavoritesWindowController(store:copyToPasteboard:)` 由用户主动 `present()` 后激活，列出收藏日期、原文预览与建议数。详情、复制和 TXT 下载共用 `FavoritesStore.text`，显示完整对应文本、建议及实际音频依据。复制读取当前收藏，再调用可注入的剪贴板写入闭包；下载文本／JSON 使用原生保存面板，告知文件为明文；删除确认只移除当前收藏。没有新录音资源、已读状态或单卡关闭状态。

## 实际检查

原 #34 切片在 Apple Silicon、Swift 6.2.3 上执行：

- `swift test --skip-build --scratch-path ../scratch/swift-build --filter FavoritesBehaviorTests`：10 个测试函数，13 个实际分支，exit 0。
- `swift test --scratch-path ../scratch/swift-build`：132 个测试函数、8 个套件，exit 0。
- `swift build -c release --scratch-path ../scratch/swift-release`：原生 AppKit release 构建，exit 0。

最高流程从真实 `RecordingApplication` 接受合成 PCM，经真实 TCP loopback 转写和 `CoachClient` 的合法模型反馈，保存独立收藏；实际删除或使来源历史到期后，fresh store 仍取回完整反馈与文本，UTF-8／JSON 文件实际读取校验；删除收藏不会修改其他历史。该流程同时覆盖卡片移走和关闭带教展示状态后的保留。

其他检查覆盖 existing history／active 不重建密钥、缺失／错误密钥拒绝明文下载且旧数据不变、收藏密文篡改后拒读／拒导出／拒覆盖且其他收藏可读、实际 allocation 使密文临时写入拒绝且回滚、历史占用／最新额度／活动预留、真实磁盘不足、调低额度不淘汰、目录／文件权限、只读目录失败保留旧密文、导出别名保护、空反馈与过大文本拒绝。

先确认缺接口为 red，再实现录音到收藏导出的 green。只读目录写入 red 揭示自动 chmod 重开写入的问题，修正后旧密文保留；带小数的日期导出 red 揭示 ISO8601 秒精度截断，改为 Unix 秒数后实际快照可回读。测试使用临时 vault、注入密钥和合成内容，没有读取用户数据密钥、收藏、剪贴板、麦克风或云端服务。

## 音频依据增量检查

本轮只在文本 renderer 增加音频依据和观察两行；收藏窗口已复用该 renderer，无需添加第二份详情逻辑。快照、密钥、加密、额度、验证和下载格式均沿用既有实现。

在 Apple Silicon、Swift 6.2.3 上执行：

- 新增 `FavoriteAudioEvidenceBehaviorTests` 的真实链路先运行 red：无润色、有润色两个分支均只因 TXT 缺实际音频依据与观察而失败，exit 1；补齐 renderer 后两分支通过，exit 0。
- `swift test --scratch-path ../scratch/swift-build --filter 'FavoriteAudioEvidenceBehaviorTests|FavoritesBehaviorTests'`：12 个测试函数、16 个实际分支，exit 0。新增检查包含旧 JSON 缺 `audioEvidence` 时语法／表达展示和无润色兼容。
- `swift build -c release --scratch-path ../scratch/swift-release`：原生 AppKit release 构建，exit 0。
- 系统临时目录中的独立 AppKit harness 构造 alpha 为 0 的隐藏收藏窗口，核验音频有／无润色及旧文本三个场景的 `NSTextView` 内容与实际 TXT 下载相同；通过注入闭包验证复制、验证 `onChange` 仍由外部 owner 持有。窗口始终隐藏、未激活，未打开保存／删除面板，exit 0。

最高流程从 `RecordingApplication` 接受合成 PCM，经真实 TCP loopback 的转写、可选 `PolishClient` 取得实际保存的原转写／润色；公开 `exportAudio` 下载 WAV，使用 AVFoundation 读取并核对实际样本。真实 `CoachClient.start(originalAudio:)` 将同一 WAV 与原转写发给本机 HTTP 端点，取得合法流利度和语法反馈，然后保存收藏、删除来源历史及测试 WAV。fresh `FavoritesStore` 读取并实际下载 UTF-8 TXT／JSON，保留 `0.123456–0.456789` 秒、中文观察与原始／润色文本；收藏目录只有既有 `.enc` 快照，vault 中已无 `.audio` 或 WAV。JSON 的日期、顶层键及音频依据字段均实际回读核验。测试使用临时 vault、注入数据密钥和假服务凭据。

## 集成后仍需验收

主集成层仍需验证从卡片／历史入口收藏真实已持久化的反馈、清空历史不级联收藏、最新资源配置／实时预留及历史缓存失效。收藏只保存文字依据，不复制原音频，也不延长原音频保留期。

本轮基线尚未将 `RecordingApplication` 的原音频 provider 接入带教；本机受控端点只证明音频协议与收藏依据保留，未验证真实 BYOK 模型听音或建议质量。隐藏控件检查未覆盖原生可见布局、实体鼠标、真实剪贴板、保存面板或删除面板。固定 SHA 后的独立 focused review 与必要对照由主 owner 安排。
