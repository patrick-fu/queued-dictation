# 重启后恢复未完成角色与中断录音

依据 GitHub #30 与父规格 #22 实现。当前分支从 `b71d3a9f378b4dd1067586ab43773bdf05c953f6` 开始；未写 App、Panel、收藏或导出算法。

## 持久化事实与恢复行为

- 第一块有效 PCM 的真实采样率先存入 `draft.enc`，随后才保存音频。重启从 0 开始逐块验证 AES 身份与连续性，遇首缺块、认证失败或无效 PCM 即停止；只把可靠前缀变为相同 UUID、顺序和起始时间的历史。没有已保存结束时点的中断录音保留 `recordingEndedAt=nil`，不推测尾部。旧采样率 0 的遗留目录保留并告警，不猜格式；无有效音频不创建空历史。
- 先加密保存 `entry.enc` 再移动 active 目录，重复启动不会复制历史。有效 active 顺序也更新下一录音的顺序底线。容量检查继续使用既有资源与整库计量；恢复失败保留原文件，不创建替代密钥。
- 录音完成的首个历史记录包含明确 ASR 未发事实。ASR 原文与润色、带教的 queued 身份在同一次 AES 更新中提交，手动重润色也先持久化新 queued 身份再注册内存工作。`waitingForSlot` 是未发事实；三个角色的 `inFlight` 在重启时转为结果未知的 `interrupted`，不视为可自动恢复的未发工作。
- 启动不会自动发送。只有持久化的正向未发事实能通过 `resumePendingProcessing` 继续，读取发送时最新服务、密钥、模型、提示词并重新开始自动发送窗口。已保存有效结果不重做；未知请求需要显式重试。关闭带教时，旧未发带教终结，不重放旧卡。
- 旧录音目标不恢复。恢复 ASR 与润色结果只进入历史和手动队头，两个交付模式均不向新文档自动填入旧片段。交付不确定仍阻住 FIFO；复制不放行，确认或跳过才终结。明确手动处置同时终结已撤销的主角色事实，独立带教保留。

## App 消费接口

`RecoveryItem` 只暴露 `id`、`interruptedRecording`、`canResumeUnsent`、`needsTranscriptionRetry`、`needsPolishRetry`、`needsCoachRetry`、`deliveryUncertain`。可执行标志排除当前 HTTP、准备工作和已在运行的角色；已恢复为正常配置等待时不再把它显示为可重复“恢复”。

- `recoveryItems() throws -> [RecoveryItem]`
- `recoveryNotice: String?`：独立的安全启动摘要，后续普通 `notice` 不覆盖；未知错误使用固定提示。
- `resumePendingProcessing(_ id: UUID) throws`
- `retryTranscription(_ id: UUID) throws`
- `repolish(_ id: UUID) throws`：既有入口名称，没有 `requestRepolish`。
- `retryCoach(_ id: UUID) throws`：已有未知或失败带教的新显式尝试。当前工作和有效结果拒绝重试，新身份及窗口先存 AES，再进入原独立调度器。

## 子进程证据

全部使用合成 8 kHz、4000 帧、单声道 16 位 PCM，临时 32 字节数据密钥、假服务凭据和 127.0.0.1。`RecoveryFaultPoint` 内部回调默认为 nil，仅挂在已存在的保存或写回边界；测试输出阶段后真 SIGSTOP，父进程确认停止状态后 SIGKILL，随后启动独立进程通过公开历史、队列、导出和实际 HTTP 检查。公开 `onChange` 已晚于 raw 保存与内存注册，故需要这一窄边界检查。

最终 18 个场景实际退出 0，HTTP 共 32 次：ASR 13、润色 10、带教 9。13 次 ASR 上传的完整 WAV SHA-256 都是 `03675581ca0efca45bbb4eb9bfcd144140b49699ca6ce3123707741495a1e677`。

| 阶段 | 公开恢复结果 |
| --- | --- |
| 无音频、首格式 checkpoint | 0 历史、0 HTTP，有独立恢复提示 |
| 首块音频已保存而计数尚未 checkpoint | 同 UUID/order、4000 可认证帧、真实 8 kHz、结束时间为空；显式恢复后仅三次角色请求 |
| entry 已保存尚未 move | 保存的真实结束时点保留，重复启动仍一条历史 |
| 坏第二块、缺第二块且第三块存在 | 两种情况均只恢复第一块 4000 帧，不跨缺口拼接 |
| 旧未知格式、缺失计数器 | 音频密文保持、无猜测历史；下一新录音 order=2 |
| raw 原子保存后尚未注册内存角色 | 原文及两个 queued 身份均存在；恢复只发润色与带教，不重 ASR |
| completed 历史的 manual polish queued | 明确恢复后只一润色请求、只更新历史 |
| 三种角色实际 HTTP 在途 | 启动及配置变更无自动请求；未知角色只经显式新尝试发送一次 |
| 润色、带教有效结果已保存 | 保留实际产物，不重请求、不重放旧卡 |
| 写回 uncertain 前、实际插入后、completed 后 | 无重复文字；uncertain 队头复制不放行、再次插入被拒、确认后放行 |
| 缺失与错误本地密钥 | 新录音拒绝、替代 key 创建次数 0、所有原密文 SHA 保持 |

这是阶段边界真实进程终止检查；未测试 Data.atomic 内部 rename 中间、fsync、断电或硬件存储故障，不能据此声称掉电事务保证。

## 实际命令与日志

工作目录：`/var/folders/5c/f170nvbx6t7105zg26q08zvh0000gn/T/queued-dictation-implementation-5y6dgm0a/recovery-runtime/queued-dictation`。证据根目录：邻接 `../scratch-recovery`。

1. 精确 b71 基线：`xcrun swiftc -parse-as-library -swift-version 6 -O baseline/exact-source/*.swift baseline/RecoveryCrashHarness.swift -o baseline/recovery-baseline`、`python3 baseline/run-recovery-baseline.py` 均退出 0。公开捕获 0.5 秒实际 4000 帧后 -9；旧实现重启 history/queue=0 且无提示，认证音频仍在 active。基线日志及原文件保存在 `baseline/`。
2. `swift test --jobs 2 --no-parallel --filter 'RecordingBehaviorTests|ModelPipelineBehaviorTests|RuntimePreparationGuardTests'` 首次退出 1：58 tests，两个额度 case 被无角色旧录音的多余启动更新误挡。仅让这类记录保持只读后，第二次对应两 case 均绿。原 `initial-recovery-focused.log` 保留。
3. 第二次范围检查 68 tests/6 suites 退出 1，唯一失败是导出 owner 的 Date 默认值 JSON 1 ULP 往返；其固定 Unix 日期修复 `ec1a3a3` 原 equality 保留。没有改导出生产模块来掩盖夹具问题。日志 `recovery-and-export-callers-focused.log`。
4. `swift test --jobs 2 --no-parallel --filter 'RecoveryBehaviorTests|ExportDestinationBehaviorTests'` 实际 9 tests/2 suites/0.261 秒，退出 0；日志 `recovery-public-and-export-focused.log`。
5. `xcrun swiftc -parse-as-library -swift-version 6 -O ../scratch-recovery/crash-final/exact-source/*.swift ../scratch-recovery/crash-final/RecoveryCrashHarness.swift -o ../scratch-recovery/crash-final/recovery-crash` 退出 0。
6. `python3 ../scratch-recovery/crash-final/run-recovery-crashes.py --binary ../scratch-recovery/crash-final/recovery-crash --output ../scratch-recovery/crash-final/run`：18 场景退出 0；`crash-final/replay.log`、`run/results.json`、`source-sha.json` 和 `current-source-check.json` 保存全部实际结果及 38 个源码/夹具 SHA。首版 runner 在 eager f-string 中读取尚未退出的 child stderr 而阻塞；own child 被安全收尾，exit130 的原日志和 sample 留在 `crash-first/`，修正 harness 条件读取后实际通过，不作为产品失败或通过证据。
7. `swift test --jobs 2 --no-parallel`：277 tests/24 suites/26.402 秒，退出 0；日志 `final-full-tests.log`。
8. `Scripts/build-app.sh release ../scratch-recovery/final-release`：17.87 秒，退出 0；`Scripts/verify-app.sh development '../scratch-recovery/final-release/Queued Dictation.app'` 退出 0。arm64/macOS 14.0 bundle 与 ad-hoc 签名验证通过，未启动 GUI；日志 `final-release-build.log` 与 `final-release-verify.log`。
9. 工作树与最终 base→HEAD 的 `git diff --check` 实际退出 0。`final-owned-processes.json` 的 capture child/runner 终态为空；没有后台服务器进程残留。

## 消费的独立固定修复

- 导出安全模块 `ae2c69e` cherry-pick 为 `189ea17`；RA 四个调用者在任何明文写入前固定实际父目录，准确调用者 patch（纯 b71 base、不含恢复）在 `export-callers-b71.patch`，供独立验收。同步 audio/raw/polish 只映射两个 typed IO 错误，源认证错误保留。
- Date 夹具 `ec1a3a3` cherry-pick 为 `ab6146b`。
- 音频运行边界 `b42ee7a` 两个生产源以精确 b71→b42 patch 消费；除了恢复的 Coach status.interrupted 域一行，运行字节逐字一致。两个授权旧 Header 断言、新边界测试和文档来自该固定 commit，证据 `audio-b42-consumer.json`。没有重写此独立修复。

本阶段不启动生产 GUI、不授予权限、不读取真实密钥或用户音频。真实 BYOK 服务、Fn/AX/TCC、实体音频采集、设备断连、多屏、30 轮原生 P95 与签名公证仍未验；这里只确认生成音频、真实本机 HTTP、AES 与独立进程边界。
