# 默认请求准备的响应性

本阶段唯一生产目录为 responsive-default-dispatch/queued-dictation，起点 `8a88b8824959da5468e7914ee1093d3e841ce7b1`。旧 model-pipeline 和 runtime-resources 树保持冻结。

## 资源审查确认的两个前置修复

- raw 已加密持久化后立即释放该 ASR 的结果预留，随后才入独立 coach 或下一 main polish。ASR 请求槽／尝试身份仍到原 defer 释放，不提前让出主请求槽，不改变 FIFO，不降低任何预留值。
- 明确的新历史 repolish 在同一次 AES entry 更新中续 anchor 并置 waitingForPolishSlot，清除旧任务 waitingForResume 资格。仍有旧 job 时拒绝重复创建；扩大配置时间窗不能解除既有暂停。新尝试只更新历史，不重 ASR、coach 或已交付文档。

检查 seam 为 public capture→实际 127 HTTP→AES raw／polish／coach→实际 NSTextView 历史交付。预算控制为 1 GiB 上限，raw 成功前填充 sparse 相关数据文件到实际剩余 4 MiB（polish）／5 MiB（coach），不改变核心预留值。重润色回归分别使用 completed 与 awaitingManualDelivery 记录，真正重新实例化 Recorder 读同一 AES vault。

| 实际命令 | exit／结果 | 邻接 scratch-responsive 日志 |
|---|---|---|
| `swift test --jobs 2 --no-parallel --filter RuntimePreparationGuardTests`，修复前 | exit 1；2 tests／4 参数，10 issues：下个角色错误 storageFailure，fresh 新尝试沿旧暂停而未 HTTP | runtime-guards-red.log |
| `swift test --jobs 2 --no-parallel --filter 'RuntimePreparationGuardTests\|RuntimeResourceBehaviorTests/manualHistorical\|ModelPipelineBehaviorTests/manualRepolish\|ModelPipelineBehaviorTests/persistence'`，修复后 | exit 0；实际匹配 4 tests／3 suites／0.321 秒；包括新角色真实 HTTP 完成、原粘性暂停和已交付历史重润色控制 | runtime-guards-green.log |

原独立 budget probe 的 `activeCount == 0` 等待条件不能用于修复后的下一 polish 在途状态。新回归先等下一角色 inFlight 或明确失败，再核 actual HTTP 并回响应，最后核槽位和预留为零；未用“函数返回早”替代实际派发。两项小 delta 的完整 full／Release 与性能阶段最终一次执行，避免重复无收益全量构建。

未验证真实 BYOK、TCC、实体输入、原生跨 App、多屏或 native 30 轮 P95。四轮合成 source.start 计时仅作为已确认 MainActor 阻塞反例及修复对照，不能代替 native 验收。

## 关闭润色时的显式历史操作

独立 review 确认：awaitingManualDelivery／completed 记录在 disabled repolish 接受后留在 waitingForPolishSlot，实际没有请求或槽位。disabled 分支现在与已存在的 receivePolish 终结规则相同，恢复 awaitingManualDelivery、completed 或 skipped；不改变 raw、已有产物、交付状态和文档，不在重新开启后续发。

为隔离后台准备 WIP，实际检查使用邻接 disabled-progress-probe：源码来自固定 620 的 git archive，再加入本次自有 public regression。修复前 `swift test --jobs 2 --no-parallel --filter RuntimePreparationGuardTests/disabledExplicitRepolish` exit 1，1 test／2 参数／2 issues，两个状态均停在 waitingForPolishSlot。初次命令 --jobs2 被 CLI 拒绝 exit 64；首次编译漏写 throwing property 的 try，exit 1，保留 disabled-progress-compile-failed.log；纠正后才取得上述行为 red。修复后 `swift test --jobs 2 --no-parallel --filter RuntimePreparationGuardTests` exit 0，3 tests／6 参数／0.134 秒，记录 disabled-progress-green.log。

## 默认三请求的后台准备

### 原因与最小机制

自然默认三个 300 秒／48 kHz ASR 在 MainActor 中逐份认证 3,516 个 AES 音频块、组装完整 WAV 与 multipart body。独立的单机制 Task／yield 实验改善 warm 轮，却仍有首轮 542.93 ms；因此仅分轮不能关闭已确认反例。实验源码与原始记录位于邻接任务 experiment-dispatch-fairness/scratch；该实验的 baseline 前后快照之间出现一个外部 swift-frontend，不能声称整段无编译污染。失败的 variant 前后快照均无相关进程。

生产现在在 MainActor 中取得已拥有的 AES key 和不可变音频描述，先加密保存未发的 waitingForSlot 尝试事实，再在 detached task 中逐块认证并组装完整 WAV／请求体；每块间检查取消。没有明文磁盘临时文件、永久音频副本、新依赖、新配置或第二准备池。原同步导出仍保留既有取消语义。准备／ready 数量受现有主并发上限约束，准备使用同一个 MainRequestBudget 与结果容量预留。

完成准备后让出旧准备槽，再按最新 main limit 申请实际发送槽；并发从 3 降到 1 时，旧准备不算已发送的请求，不会继续同时 POST 3 份。发送前重新核身份／世代、主额度、服务／模型／密钥、未发时间窗、网络和容量。模型变更只在同一次未发尝试中后台重建 body，不重读 WAV、不产生隐藏请求。HTTP 之前才加密保存 inFlight 并开始完整截止；缺配置、断网、ready 等待均不消耗请求截止。准备失败需显式重试；取消、删除、停止和退出清除身份，取消 worker 并释放一次占用，迟到完成不能复活。普通 stop 之后仍可显式新工作。

### 同一实际 fixture 的对照

所有计时均使用同一统一 Harness SHA `e3931770d2a13ba2f0aef7579ef3afe8f5a06f05c211800f2586558f03b244c5`。B 在首次实际派发容量 callback 中由后台排入 MainActor，不等三份准备完成。HTTP server 收齐三份完整上传并等 B 的 SyntheticCapture.source.start 握手后才响应 503；不以 pump 提早返回代替实际三请求派发。默认额度、主／coach 3／3、整体截止和等待界限均未修改。

fixture 为每段 14,400,000 帧、28,800,044 B 完整 mono PCM WAV；SHA 为 `9a654d57622a47aba525d413ba48a363bb46e95a82a3606ff95371d51eaed647`。3 默认段加 1 秒 control 的 pending 为 4 段／901 秒／129,744,896 B，低于默认 256 MiB。复制的 seed 只有 AES 文件，copied PCM plaintext files 为 0。

| exact source／实际检查 | B trigger → source.start 四轮 ms | sync pump 四轮 ms | exit |
|---|---|---|---|
| baseline-observed：固定 8a88b882 | 758.942／417.631／403.233／382.792 | 757.851／513.850／505.761／479.067 | 0，9.127 秒 |
| fixed-observed：后台初稿，中间 snapshot | 2.721／3.125／3.266／3.829 | 2.013／102.512／97.578／96.873 | 0，7.727 秒 |
| final-observed：本阶段最终三个 Core 文件 | 3.184／5.179／4.059／4.328 | 2.418／104.183／98.195／98.808 | 0，8.189 秒 |

每组各 actual 12 POST／12 responses、四个 cohort 峰值 3、完整 WAV SHA 全部相同，无丢帧、重复请求或响应前释放握手。FIFO 乱序、取消和已交付历史行为由原完整行为套件覆盖。每组开始／终态 compiler／timedbinary 快照均为空；这仅是快照，不能证明整个时间段主机绝无外部负载。server thread 均确认停止。最终性能复制源码 SHA：

- RecordingApplication.swift：`5e2ff3a78b2c7cf6b6bc8c75c8afd6b35f6143ffb89514c9f6895d11519facf0`
- EncryptedHistory.swift：`ccd54f186eb40ce58e8404d3b2ba3fc13bedbab05d9da579906186def5cfb7ee`
- Transcription.swift：`1481a54130499e9f5ba7ae4c025961c1ae7a62a1f35cf508dc0bb85a6fbcc0fa`

执行 `python3 ../../perf-default-preparation/scratch/prepare_replay.py --repo . --output ../scratch-responsive/final-observed` exit 0，再用上述同一 Harness 替换观测入口，`python3 aggregate_experiment.py compile` exit 0／23.814 秒，`python3 aggregate_experiment.py run` exit 0。manifest 逐文件 SHA、精确 argv、原始计时和 server 记录均在邻接 scratch-responsive/final-observed。第一次 wrapper 路径少一个父级 exit 2，保留 fixed-prepare-wrapper.log；没有据此声称执行成功。baseline 原同步观测版本只编译未运行，保留 baseline 目录。

### 行为检查与实际失败

新独立 ResponsiveDispatchBehaviorTests 使用 public Recorder→真实 loopback HTTP，检查首次触发新采集时未发完三个请求，同时最终三份完整 WAV 真正到达。该回归不拿 CI 墙钟作为 native 性能判定。三个准备仍未 HTTP 时立即降到 1，并换另一个 127 endpoint／模型／密钥；随后只有新端点逐份收到 1 请求，旧端点 0。虚拟截止提前到 1,000 后请求仍从实际 send 起计。断网／时间窗扩大没有偷续发，明确 resume 才发送；cancel、delete、stop、prepare 四参数验证旧 worker 不能复活，以及 stop 能接受新的显式工作。

| 实际命令 | exit／结果 | scratch-responsive 日志 |
|---|---|---|
| `swift test --jobs 2 --no-parallel --filter ResponsiveDispatchBehaviorTests`，同步源 | 1，1 test／8.625 秒，仅 B 开始时三个请求已全发的关键断言失败；完整 WAV／计数均通过 | responsive-dispatch-red.log |
| 同上，后台初稿 | 0，1 test／7.714 秒 | responsive-dispatch-first-green.log |
| `swift test --jobs 2 --no-parallel --filter 'ResponsiveDispatchBehaviorTests\|RuntimePreparationGuardTests\|ModelPipelineBehaviorTests\|RuntimeResourceBehaviorTests\|TranscriptionBehaviorTests\|QueueBehaviorTests'` | 1，92 tests／6 suites／23.154 秒；仅原网络在初始 reserve callback 关闭后等待状态／槽／预留的 3 issues | preparation-controls-focused.log |
| `swift test --jobs 2 --no-parallel --filter 'ResponsiveDispatchBehaviorTests\|RuntimePreparationGuardTests\|RuntimeResourceBehaviorTests/aNetworkChangeDuringResultReservation'`，恢复初始 reserve 后未发门禁 | 0，8 tests／3 suites／8.822 秒；实际 ASR／polish／coach 全门禁以及新控制均通过 | preparation-controls-final-green.log |
| `swift test --jobs 2 --no-parallel`，最终完整仅一次 | 0，250 tests／18 suites／24.909 秒；旧测试未改，未出现先前 parallel wait 失败 | final-full-tests.log |
| `Scripts/build-app.sh release ../scratch-responsive/release` | 0，production build 16.51 秒，arm64 App bundle 与 ad-hoc codesign verify 均成功 | final-release-build.log |
| `Scripts/verify-app.sh development '../scratch-responsive/release/Queued Dictation.app'` | 0，macOS 14／arm64／bundle／开发签名检查通过；未启动 GUI | final-release-verify.log |

新增控制首次编译误写 cancel API 名，exit 1，保留 preparation-controls-compile-failed.log；纠正 API 后才执行行为检查。未加长任何旧等待截止；没有以盲 full 重跑掩盖失败。

本阶段关闭的是上述受控默认三请求准备阻塞反例。未测真实 Fn、TCC、实体音频 source、最低系统 30 轮 A/B、原生多屏／跨 App 或 native P95≤500 ms；未使用真实 BYOK、用户音频或真实 App 数据。

收尾检查使用实际基线到当前 diff 与提交本身的 diff，均为 `git diff 8a88b882..HEAD --check`／`git diff HEAD^ HEAD --check`，不能以 clean 工作树的空 diff 替代。本阶段未续写旧 frozen 工作树、App／Panel、Coach provider、Favorites／Retention／helper／Network／Backoff 模块，也未实施下一阶段历史导出、收藏入口或原音频 provider 接线。
