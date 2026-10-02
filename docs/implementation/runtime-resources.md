# 运行时资源与派发接线

## 主流程审查回归检查点

- 手动插入先记录处理世代和队头产物；释放润色槽位可能同步触发观察者，因此返回后重新核验退出、停止、取消和队头，再持久化不确定状态及写入目标。
- completed 历史和 awaitingManualDelivery 的手动重润色同样受未发时间窗约束。过期会保留 waitingForResume；扩大配置时间窗不解除暂停，显式恢复才续窗。已完成交付不会重放。
- 带教设置开关即时保存到同一 scheduler；App 渲染只同步 checkbox。保存其它字段使用 scheduler 当前总开关，保留 model、prompt、concurrency、timeout、corner、inputMode 草稿。

2026-10-03 在 macOS、Swift 6.2.3 执行：

| 检查 | 实际结果 | 原始日志（工作树邻接 scratch-runtime） |
|---|---|---|
| `swift test --jobs 2 --filter RuntimeResourceBehaviorTests` 修复前 | exit 1，两个测试、五组参数，重入写文档及超窗断言失败 | confirmed-core-red.log |
| `swift test --jobs 2 --filter 'RuntimeResourceBehaviorTests\|ModelPipelineBehaviorTests/currentCandidate\|ModelPipelineBehaviorTests/exitPermanently\|ModelPipelineBehaviorTests/automaticSending'` 修复后 | exit 0，实际匹配三个测试；含已有正常队头插入控制 | confirmed-core-green.log |
| 隐藏设置窗口真实 NSButton 草稿／开关探针，修复前／后 | exit 1 两断言失败 → exit 0 一个测试 | confirmed-ui-red.log / confirmed-ui-green.log |
| `git diff --check` | exit 0 | 终端输出 |

Core 回归使用生成 PCM、127.0.0.1 HTTP 服务、AES 历史、实际 NSTextView。UI 探针源码位于 `Tests/RuntimeUIProbes/CoachSettingsSwitchTests.swift`。它通过独立临时 Swift package 编译真实 `CoachSettingsWindowController.swift` 到 `RuntimeUI` target（依赖本树 DictationCore），运行 `RuntimeUITests`；未启动生产 App、未展示窗口、未授予 TCC、未读真实密钥或音频。App 的统一 render 显式调用 `synchronizeEnabled()`；探针以 scheduler.onChange 驱动相同入口，避免重载整个表单。

当前检查点不代表原生键盘、跨 App、多屏、BYOK 网络、P95 或各 GitHub 整票验收完成；资源／网络完整接线将在同工作树后续独立提交记录。
