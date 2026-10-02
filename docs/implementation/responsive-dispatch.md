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
