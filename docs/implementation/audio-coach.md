# 原始音频英语带教

对应 issue #33，继承 #32 的统一带教开关、单一独立池、最多一张卡片及两条建议、尝试身份和迟到规则。此文件记录 Coach 模块切片；实际从加密历史读取本段 WAV、历史保存和 App 接线由主实现 owner 验证。

## 输入方式和请求

`CoachConfiguration.inputMode` 为 `text` 或 `originalAudio`，默认文本。旧配置 JSON 缺此字段仍按文本读取。两种方式共用原有带教池，默认并发 3，不建立第二个带教池。

公开 `CoachWorkScheduler` initializer 增加默认不提供音频的 `audioForSegment: (UUID) throws -> Data?`。仅在外部派发门通过、配置及凭据有效、实际选用音频方式时读取本段原音频；等待槽位、等待恢复、文本方式、缺角色／凭据均不解密音频。此 provider 应按片段身份返回既有加密历史的 WAV，不额外持久化副本。公开 `CoachClient.start` 的 `originalAudio: Data? = nil` 保持旧文本调用兼容。提供数据也不会使文本方式偷偷发音频。

音频请求的同一条 user message 包含本段原始转写 text part 与 `input_audio` part：`input_audio.data` 是完整原始 WAV 的 base64，`input_audio.format` 为 `wav`。system message 为本次完整提示词。请求仍只有 `model`、`messages` 和 `stream:false`。OpenAI 的 [Chat 音频官方指南](https://developers.openai.com/api/docs/guides/audio-chat-completions)及 [Chat 内容类型参考](https://developers.openai.com/api/reference/resources/chat)说明了此 WAV/base64 输入格式。本实现直接使用 URLSession，没有 SDK、分类请求、修复请求、协议回退或自动补发文本。

原音频 provider 是一次同步可重入调用。读取前先验证当前配置／凭据，避免无效配置解密音频；回调返回后重新读取 enabled、inputMode、role、服务地址、凭据和完整提示词，再构造实际请求。已读 WAV 仅在最新方式仍为音频时使用；改为文本不附音频，也不要求此前 provider 有音频结果。最新配置缺失、凭据缺失或关闭时不发送。只读取本段音频一次、不递归重准备；整个调用的起始时刻只捕获一次，配置刷新不会重启截止计时。这关闭 provider 回调这一已实证配置窗口，不声称跨进程原子事务。

没有未经实际核验的 `response_format` 开关。音频输入与严格 schema 支持是独立能力：本实现始终校验同次返回的内容；models 列表、文本成功、音频字段存在或格式合法均不能证明模型确实理解了音频。

## 原音频和有界请求

`AudioCoachInput` 校验 RIFF/WAVE 长度、唯一且有效的 PCM fmt、唯一非空且帧对齐的 data，以及字节率。输入与既有历史格式一致：单声道 PCM16、8–192 kHz，时长大于零且至多 60 分钟。WAV 头及其他元数据至多 65,536 bytes；WAV 总上界为 1,382,465,536 bytes，覆盖父 spec 允许的单段 60 分钟及 192 kHz，低于最大积压 2,048 MiB 的容量。base64 上界由受限的 WAV byte count 推导，JSON 上界再预留 4 MiB 给受限的提示词、原文和转义，编码后也再次检查。无任意短样本时长限制。

准备和编码目前在公开同步调用中进行，截止从实际开始构造请求覆盖准备、上传、响应体读取和完整有效结果；完整结果回到主 actor 后仍检查截止。过期、取消、删除、stop 的网络任务实际取消，迟到不覆盖新尝试或复活历史。关闭已经发送的请求保留既有尽力取消规则；合法结果已到达持久化时关闭，只入历史，不展示／重放。

`CoachDispatch` 只记录尝试身份、所选服务／模型／提示词／截止，以及实际请求是否含音频的 `audioUsed`、格式和时长，不放原音频、base64 或密钥。旧 dispatch JSON 缺新增字段默认无音频。准备／持久化失败不会产生合法反馈；保存 inFlight 是发送前的守护记录，不能据此推断远端已经接收或理解音频。

## 卡片契约

文本语法／表达保留原契约：严格字段，连续 original 必须逐字存在于原转写，改进和理由非空且有界，无 score 字段。一张卡片总共一到两条建议；`{"kind":"no_card"}` 仍为成功的无卡结果。

音频方式允许 `fluency`，但它不使用 original 字段，避免把转写引用当作听到的依据。流利度项精确包含 `category`、`improved`、`reason`、`audioEvidence`；后者精确包含 `startSeconds`、`endSeconds`、`observation`。时间为有限数字且不是 bool，范围 `0 ≤ start < end ≤ 本次实际 WAV 时长`，观察非空且有界。仅真正构造含有效原音频的请求才把该时长传给响应校验；文本请求拒绝所有流利度项。此校验证明结构、引用和本段音频来源，无法自动证明模型所述观察与教学语义真实。

卡片在 begin 时记录实际 inputMode，后续修改设置不会把旧文本卡片标为音频。音频卡片显示来源以及具体时间范围、观察和练法。流利度建议的持久化结构保留原有 `original` 属性为空字符串，并用可选 `audioEvidence` 提供真实音频依据；旧建议 JSON 缺 evidence 仍可读取。

## 设置和失败

保持一个总开关。设置显式选择文本或原始音频方式，告知向所选服务额外发送本段原音频以及不能从文本请求成功推断音频能力。完整提示词可编辑和恢复；nil 默认随方式适配，自定义来源不因字符串恰好等于默认值而被抹掉。

音频缺失、无法读取、无效／过大与音频不兼容有独立可见失败。提示用户修复服务／历史或切换为文本方式后显式重试。失败不会自动发第二次文本 HTTP，不影响主输入交付。

## 已执行检查和未验证范围

- 首先在旧实现上得到行为 red：音频配置缺音频时仍可发送文本；给原 WAV 后 user content 仍是文本 string。补实现后两项 green。
- 合成 PCM 由 AVAudioFile 写成真实 WAV，再经 AVAudioFile 独立解码并比较逐样本；公开 scheduler/client →真实 127.0.0.1 TCP →独立 JSON/base64 解码检查 WAV bytes 及原始转写 →合法两条建议 →公开 panelState 和保存 update/dispatch。受控响应证明编码和契约，不冒充真实模型听力／教学质量。
- 新行为检查覆盖文本零音频读取／伪流利度拒绝、持有 gate 零音频／凭据读取、最新方式／模型、共用三槽及旧卡来源不变、无卡、缺音频／不兼容／无效 schema、布尔和越界时间、截止／重试、关闭／删除／取消／stop 与不自动补发。
- 60 分钟 8 kHz PCM WAV 经独立 AVAudioFile 解码长度正确并通过输入校验；多一个 frame 或截断／奇数 PCM 拒绝。未分配 60 分钟 192 kHz、base64 约 1.8 GiB 的极限请求。
- 一次独占默认 5 分钟／48 kHz 合成 WAV（28,800,044 bytes）的实际公开 client 构造对照：文本 6.65 ms、main actor heartbeat 6.68 ms；音频 60.81 ms、heartbeat 60.86 ms。它只覆盖请求构造，不包含真实 store 解密、Mic／TCC、录 B 的完整 P95 或最大额度性能。大段同步编码占用会随数据量增大，这是未验证的性能风险。
- `swift test --filter AudioCoachBehaviorTests` 通过 16 tests / 1 suite；`swift test` 通过 138 tests / 8 suites（包含原有文本和主输入回归）；`swift build -c release` 完成构建，均实际 exit 0。配置回归同时证明 `3.0000000000000001`／`0.99999999999999999` 原始 JSON 并发值拒绝且文件 bytes 不变，合法 concurrency 3 和 timeout 5.75 保持。
- 未连接用户所选真实 BYOK 音频服务，没有使用生产凭据或用户音频；真实音频能力样本、教学依据真伪、原生设置／浮窗焦点和全屏／Space 仍须实机验证。没有这些证据不能把 issue #33 记为完整验收通过。

provider 配置回归：旧实现的两个真实本机端点、文本／音频两个变体实际出现旧 URL、模型、密钥、提示词与 dispatch 来源，新增测试得到 15 项 red。修复后同一回归 green，旧端点零 POST，新端点仅一次 POST 并记录最新来源；另检验仅换 key、仅切文本且 provider 返回 nil，以及缺 role／key／disabled 时零发送。`swift test --filter AudioCoachBehaviorTests` 通过 20 tests；原文本兼容回归通过。并发 JSON 在系统 decoder 验证完整语法和类型后，使用共用 `ExactIntegerJSONFields` 对原始 concurrency token 做整数核验。四条原始小数输入（包含超过 Decimal 精度的尾数）实际拒绝，原文件 bytes 保持；1.0、1e0、0.3e1、300e-2、10.0 和长零尾数等数学整数保持，timeout 5.75 仍按 Double 域处理。超精度两条先在未接入 helper 的 public load 上实际 red，再 green。

上述两个必要修复的最终检查：`swift test --filter CoachBehaviorTests` 实际通过 39 tests / 2 suites（包含 Audio 20 tests 和既有文本回归），`swift build -c release` 完成，`git diff --check` 无输出，均 exit 0。没有重新扩大既有时长消融、UI／Mic／BYOK 或极限压力试验；这些未验证范围保持。
