# 录音快捷键与独立原生界面

本 checkpoint 为 Issue 25 的独立模块：触发、设置持久化、设置窗口和录音胶囊已实现并构建。共享 `AppDelegate` 仍由转写票的 owner 修改，尚未挂接这些模块；这不是运行中的 App 已完成快捷键验收。

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
| `shutdown()` | 注销监听并移除回调；App 仍需负责当前录音的保存／取消与退出收尾。 |

控制器不替换 `RecordingApplication.onChange`。共享 App 的现有渲染回调须显式调用 `synchronize()`；设备失败、时长／空间自动停止与按钮操作才能及时反映到胶囊。控制器的 `onChange` 可同时更新胶囊和已打开的快捷键设置窗口。

```swift
model.onChange = { [weak self] in
    self?.render() // 保留共享 App 的现有录音／转写显示。
    self?.hotkeyController.synchronize()
}
hotkeyController.onChange = { [weak self] in
    guard let self else { return }
    self.recordingCapsule.render(self.hotkeyController.presentation,
                                 cancellation: self.hotkeyController.listenerStatus.cancellation)
    self.hotkeySettings?.render()
}
```

启动、停止与取消各自保留动作代次；设备收尾或原授权请求仍未返回时，`isTransitioning` 仍为 true，不接受下一段。授权等待期间的松开／取消走 `cancelCurrentRecording()`，使迟到授权不能复活这次采集。按键自动重复与重复按下不切换录音；停止中的新按下不会排队成为下一段。App 退出需要同时考虑 `RecordingApplication.state` 和 `isTransitioning`，在授权或启动未完成时先取消当前动作，再注销监听。

`HotkeyConfigurationStore` 只保存快捷键入口与手势的 JSON，使用独立 UserDefaults 键，不含模型凭据或语音正文。解码失败及不支持的配置会抛出明确错误，原数据不被覆盖；App 加载失败时须显示错误，供用户重新配置。保存前保留该键的原始值；保存失败会回退当前值，原本不存在则移除本次新增值，再尝试同步原值。即使回退同步仍失败也明确报“持久化未确认”，不把内存回退当成磁盘保存成功，不更新控制器配置，也不改其它偏好。

## 原生适配

Fn 使用 session 层 `CGEvent` listen-only tap，仅订阅 modifier 变化并筛选 Apple Fn 键码 63；不修改或丢弃系统事件。组合键与录音期间的 Esc 使用 Carbon exclusive hotkey 注册。注册冲突不会回退为非独占注册，也不会显示成功。Carbon 注册代次过滤配置切换后的旧事件；监听恢复时先读取当前键状态，已按住的键不会变成一次新按下。

`HotkeyListenerStatus` 分别记录录音入口和取消入口状态、`CGPreflightListenEventAccess()` 的实际结果，以及读取的 `AppleFnUsageType`、标准 F1/F2 偏好。预检不能区分尚未请求、拒绝与撤销，因此统一说明“未获准”。Fn tap 未建立、未启用或监听撤销均显示 unavailable，并提供组合键／App 入口。监听中断会安全结束由快捷键启动的当前录音，并失效旧按住状态与松开所属代次，避免丢失 release 后恢复的第一按下被忽略。重新授权及用户主动重试可重建监听；原生适配的物理当前按住保护保持有效，恢复本身不开始录音，旧 release 不能结束 App 入口开始的新录音。

设置窗口的“输入监控设置”由用户主动打开系统设置；此模块不自动索取 TCC，不改用户的 Fn 设置。第三方 Fn 拦截或争用不在本票处理范围。`ready` 只表示监听／注册实际建立，设置文案为“Fn 监听已启动”，不能据此宣称实体 Fn 已验证。

`HotkeyRecordingCapsule` 使用 `.nonactivatingPanel`，拒绝成为 key/main window；自动出现只调用 `orderFrontRegardless()`。可见状态来自真实采集、授权等待、收尾和实际结果，包括额度拒录及采集错误。结果被主动关闭后，监听权限等无关状态刷新不重新弹出旧结果。设置窗口只在用户主动打开时激活；组合键录入期间注销全局入口，完成或失焦后恢复。

## 当前检查与缺口

- `swift test --filter HotkeyRecordingBehaviorTests`：18 项通过，保存失败覆盖有旧配置／无旧配置两个用例。从可控的外部快捷键／麦克风边界检查真实状态、加密历史、可解码 WAV 与用户可见结果；没有使用用户音频或生产钥匙串。
- 关键新增行为先记录 red 再实现 green；设备收尾、额度拒录与采集失败作为已有公开机制的行为回归加入。
- `swift build`：包括两个独立 AppKit 文件与原生监听适配器，构建通过。
- Review 修复后收尾 `swift test`：两套共 33 项通过；`swift build -c release` 通过；diff 的空白检查通过。失联恢复的第一按下真实形成 B（WAV 2,000 帧），先前 A（4,000 帧）原字节保留；旧 Fn 松开不结束 App 新录音，失败保存不覆盖非法原始配置字节或其它偏好。
- 开发主机实际为 macOS 26.6.2（25G83）、Apple Swift 6.2.3。测试日志的 `arm64e-apple-macos14.0` 为部署目标，不是 macOS 14 实机验证。

本轮未运行原生 App 申请权限或真实录音。Mac 锁定时不绕过登录或 TCC；没有使用合成 CGEvent 操作用户 UI。内置 Apple Fn、外接 Apple Fn/Globe、组合键的两种手势、真实首次授权／拒绝／撤销／恢复、跨 App 输入焦点、全屏／Space 与多显示器仍未验收。真实 Fn 证据不能由合成事件、旧探针或注册成功替代。基础票 23 的原生验收依赖仍开放，Issue 25 不应据此关闭。
