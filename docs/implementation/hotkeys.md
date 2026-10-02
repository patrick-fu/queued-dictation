# 录音快捷键与 App 生命周期

Issue 25 的触发、设置持久化、设置窗口和录音胶囊现已接入 `AppDelegate` 与原有转写入口。App 保留一个录音模型、一个监听器和一个快捷键生命周期实例；不另外创建录音或转写通道。构建与受控行为检查已经完成，原生 App 的实体键盘、TCC 和焦点验收仍需单独执行。

## 入口与状态

`HotkeyRecordingController` 在 `MainActor` 上使用同一 `RecordingApplication`，默认选择 Fn、按住录音松开结束；可选择组合键与点按切换。组合键使用 Apple 物理虚拟键码，支持普通键、方向键、功能键及标准修饰键。无修饰键、Fn 作为普通键、未知按键或未知修饰位会明确拒绝。建议组合键是 Command–Shift–M。

| 接口 | 用途 |
| --- | --- |
| `toggleRecordingFromApp()` | App 主动开始或结束录音，Fn 监听不可用时仍可使用。 |
| `cancelCurrentRecording()` | 只丢弃当前采集；不操作之前已入库或处理中片段。 |
| `updateConfiguration(_:)` | 切换入口或手势；旧快捷键启动的录音先结束，旧入口事件不能控制新配置。 |
| `setShortcutEntryActive(_:)` | 录入组合键期间暂停全局触发；已有快捷键录音安全结束。 |
| `synchronize()` | 从真实录音状态与结果更新胶囊状态，并按当前录音开启／撤销 Esc 取消。 |
| `refreshListenerStatus()` | 检查实际预检权限、Fn tap 与系统 Fn 设置，供 App 定时器调用。 |
| `retryShortcutRegistration()` | 用户主动重试不可用监听；录音或收尾期间只检查，不重注册当前入口。 |
| `finishForTermination() async` | 收尾已有录音动作；App 先同步 `beginTermination()` 冻结录音／处理，再等待保存或取消；不等待授权弹窗返回。 |
| `shutdown()` | 注销监听并移除回调，阻断后续 App／快捷键动作；当前音频收尾由 `finishForTermination()` 完成。 |

`HotkeyApplicationSession` 管理 App 的快捷键配置与生命周期。初始化时读取设置；非法 JSON、非法组合键或非 Data 值均保留原数据、显示读取错误并暂停全局入口。App 按钮仍可录音。只有 `saveConfiguration(_:)` 成功才解除配置错误与暂停；录入组合键的暂停由同一实例管理，窗口关闭或失焦后恢复实际配置。

控制器不替换 `RecordingApplication.onChange`。App 保留原有录音／转写渲染回调，在 `render()` 里调用 session 的 `synchronize()`；设备失败、时长／空间自动停止与按钮操作反映到胶囊。session 的 `onChange` 更新胶囊、按钮收尾状态与已打开的快捷键设置窗口，不递归调用录音模型。

```swift
model.onChange = { [weak self] in
    self?.render() // render 内调用 hotkeySession.synchronize()。
}
hotkeySession.onChange = { [weak self] in
    guard let self else { return }
    self.recordingCapsule.render(self.hotkeySession.presentation,
                                 cancellation: self.hotkeySession.controller.listenerStatus.cancellation)
    self.hotkeySettings?.render()
}
```

启动、停止与取消各自保留动作代次；设备收尾或原授权请求仍未返回时，`isTransitioning` 仍为 true，不接受下一段。授权等待期间的松开／取消走 `cancelCurrentRecording()`，使迟到授权不能复活这次采集。按键自动重复与重复按下不切换录音；停止中的新按下不会排队成为下一段。

App 的 250ms 定时器调用 `checkConditions()`，同时检查录音条件与监听实际状态。App 按钮走同一控制器，菜单栏与设置页面提供“录音快捷键”入口。session 在录音模型捕获交付目标前隐藏 `starting` 胶囊状态；`startRecording()` 内捕获目标之后才显示授权或采集状态。此顺序检查不能证明真实窗口不抢焦点。

退出先同步 `beginTermination()`：置终止标记并立即调用 `RecordingApplication.prepareForTermination()`，先冻结新的录音与处理、使等待授权的代次失效，再注销监听、隐藏胶囊并阻断新入口。即使授权 continuation 已排在异步收尾之前，也不能变成采集；此阶段不等待系统弹窗回复。`requiresTerminationWait` 同时看真实录音状态与未完成控制动作；需要收尾时返回 `.terminateLater` 并等待 `finishForTermination()`。退出前已开始的采集安全保存已有音频，原已取消动作继续丢弃；保存不创建新的转写尝试或请求，保留待后续显式恢复。重复退出请求等待同一次终止，不绕过录音收尾；最终清除 UI／模型回调与定时器。

`HotkeyConfigurationStore` 只保存快捷键入口与手势的 JSON，使用独立 UserDefaults 键，不含模型凭据或语音正文。解码失败及不支持的配置会抛出明确错误，原数据不被覆盖；App 加载失败时须显示错误，供用户重新配置。保存前保留该键的原始值；保存失败会回退当前值，原本不存在则移除本次新增值，再尝试同步原值。即使回退同步仍失败也明确报“持久化未确认”，不把内存回退当成磁盘保存成功，不更新控制器配置，也不改其它偏好。

## 原生适配

Fn 使用 session 层 `CGEvent` listen-only tap，仅订阅 modifier 变化并筛选 Apple Fn 键码 63；不修改或丢弃系统事件。组合键与录音期间的 Esc 使用 Carbon exclusive hotkey 注册。注册冲突不会回退为非独占注册，也不会显示成功。Carbon 注册代次过滤配置切换后的旧事件；监听恢复时先读取当前键状态，已按住的键不会变成一次新按下。

`HotkeyListenerStatus` 分别记录录音入口和取消入口状态、`CGPreflightListenEventAccess()` 的实际结果，以及读取的 `AppleFnUsageType`、标准 F1/F2 偏好。预检不能区分尚未请求、拒绝与撤销，因此统一说明“未获准”。Fn tap 未建立、未启用或监听撤销均显示 unavailable，并提供组合键／App 入口。监听中断会安全结束由快捷键启动的当前录音，并失效旧按住状态与松开所属代次，避免丢失 release 后恢复的第一按下被忽略。重新授权及用户主动重试可重建监听；原生适配的物理当前按住保护保持有效，恢复本身不开始录音，旧 release 不能结束 App 入口开始的新录音。

设置窗口的“输入监控设置”由用户主动打开系统设置；此模块不自动索取 TCC，不改用户的 Fn 设置。第三方 Fn 拦截或争用不在本票处理范围。`ready` 只表示监听／注册实际建立，设置文案为“Fn 监听已启动”，不能据此宣称实体 Fn 已验证。

`HotkeyRecordingCapsule` 使用 `.nonactivatingPanel`，拒绝成为 key/main window；自动出现只调用 `orderFrontRegardless()`。可见状态来自真实采集、授权等待、收尾和实际结果，包括额度拒录及采集错误。结果被主动关闭后，监听权限等无关状态刷新不重新弹出旧结果。新的录音尝试先进入隐藏状态并清除上次关闭记录，即使再次得到相同的麦克风或额度拒录也会显示；捕获交付目标前仍保持隐藏。设置窗口只在用户主动打开时激活；组合键录入期间注销全局入口，完成或失焦后恢复。

## 当前检查与缺口

- `swift test --filter HotkeyRecordingBehaviorTests`：18 项通过，保存失败覆盖有旧配置／无旧配置两个用例。从可控的外部快捷键／麦克风边界检查真实状态、加密历史、可解码 WAV 与用户可见结果；没有使用用户音频或生产钥匙串。
- 关键新增行为先记录 red 再实现 green；设备收尾、额度拒录与采集失败作为已有公开机制的行为回归加入。
- `swift build`：包括两个独立 AppKit 文件与原生监听适配器，构建通过。
- 独立模块 Review 修复后 `swift test`：两套共 33 项通过。失联恢复的第一按下真实形成 B（WAV 2,000 帧），先前 A（4,000 帧）原字节保留；旧 Fn 松开不结束 App 新录音，失败保存不覆盖非法原始配置字节或其它偏好。
- App 初次接线的 `HotkeyApplicationBehaviorTests`：9 个检查通过，其中 Fn／组合键 × 按住／点按为 4 个用例。生成 PCM 通过真实 `127.0.0.1` TCP `/audio/transcriptions` 请求，检查请求中的模型与实际 WAV 样本、加密历史和目标文档结果；另检验 A 处理中取消 B、配置错误／保存失败、监听／麦克风状态变化与三个退出时机。
- App 目标捕获顺序使用可控 `TextDelivering` 文档和展示回调检查；没有执行真实 TextEdit／AX 写回，不能作为跨 App 焦点或胶囊窗口的实机证据。
- 初次 App 接线 `swift test` 的 4 套共 61 个检查与 release 构建通过；独立 review 随后发现授权排队与新请求反例，原检查没有覆盖这两个时间顺序，不能据此认定退出行为已满足。
- 退出回归先在原 `99027c0` 的生产源码上得到行为 red：同步退出前／后排入的授权均生成 4,000 帧 WAV，退出活动采集也发送真实本机 POST。合入 core 退出门后，App 尚未调用该 API 时仍保存了迟到采集并创建新 attempt；完成同步接线后，两种授权顺序均为零历史／零请求，活动 prefix 的 WAV 4,000 帧与原 PCM 一致、没有 attemptID 或新请求。
- 重复拒录先检查真实 session 轨迹：新尝试为 `hidden → result`，无关条件刷新保留原 `result`。另用透明、不激活的自有 AppKit 面板和真实关闭 action 检查：原版第二次相同拒录不显示，修复后重新显示；旧结果刷新仍保持关闭。这只证明构造对象的提示生命周期，不证明实体键盘、TCC 或跨 App 焦点。
- 本轮 App 聚焦检查为 11 个 test，完整 `swift test` 为 5 套共 83 个 test，均通过；`swift build -c release` 与 diff 空白检查通过。退出与重复拒录修复只改 session 的同步调用和胶囊关闭抑制，不改核心队列实现。
- 开发主机实际为 macOS 26.6.2（25G83）、Apple Swift 6.2.3。测试日志的 `arm64e-apple-macos14.0` 为部署目标，不是 macOS 14 实机验证。

本接线回合未启动新原生 App 申请权限或真实录音，临时文件、生成音频、测试密钥与本机服务均在隔离测试环境；未使用用户音频或生产钥匙串，未上传到外部服务。主线已确认原生界面可访问，实机检查将由主线在此固定版本审查后统一执行，避免双实例；没有使用合成 CGEvent 操作用户 UI。内置 Apple Fn、外接 Apple Fn/Globe、组合键的两种手势、真实首次授权／拒绝／撤销／恢复、跨 App 输入焦点、全屏／Space 与多显示器仍未验收。真实 Fn 证据不能由合成事件、旧探针或注册成功替代。基础票 23 的原生验收依赖仍开放，Issue 25 不应据此关闭。
