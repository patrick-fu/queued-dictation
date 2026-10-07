# 润色客户端切片

本实现是 [#28](https://github.com/patrick-fu/queued-dictation/issues/28) 的独立客户端、设置和界面切片。父规格 [#22](https://github.com/patrick-fu/queued-dictation/issues/22) 的队列与全票验收继续由集成实现完成。

## 派发接口

`PolishClient(settings:services:credentials:networkConfiguration:timing:)` 复用 `ServiceSettings` 和 `ServiceCredentialStoring`，使用独立的 `PolishSettings` 文件保存角色选择与提示词。实例不分配并发槽位；队列取得转写＋润色共享槽位后调用 `dispatch(rawTranscription:attemptID:beforeSend:completed:)`。在途字典只保持任务生命周期与拒绝重复尝试 ID。

每次派发读取最新润色开关、角色、提示词、截止、共享服务和当前有效凭据 slot。返回 `.disabled`、`.waiting(PolishFailure)` 或 `.started(PolishAttempt)`。启用但缺角色、服务或密钥时返回等待，不发送请求，也不回调已发失败。无鉴权服务不读取或发送旧凭据。UI 和队列可读取 `readiness`，配置齐全只代表具备发送条件。

`beforeSend` 是同步的尝试持久化步骤，使用尝试 ID、服务 ID 和模型保存 `inFlight`；失败则网络任务不启动。`deadline` 在真正 resume 时建立，返回 `.started` 后可读。调用方须把派发放在取得槽位后，并在进入此回调前完成片段有效性、资源和时间窗检查。已发送尝试保持该次配置快照，设置修改不会重发。

`PolishAttempt.cancel()` 和 `PolishClient.cancelAll()` 取消实际 URLSession 任务。`PolishCompletion` 含尝试 ID 与有效文本或角色失败原因。客户端只接纳一次终态；完整截止及回调接纳都检查单调时间。队列仍须核验片段／角色／尝试身份，不能仅靠客户端终态守护接受已经被取消、删除或替换的工作。

## 请求和结果

通用 `/chat/completions` JSON 只有 `model` 和两条 `messages`：`system` 为完整提示词，`user` 为本段未经润色的原始转写。没有窗口、屏幕、剪贴板、音频或其他片段内容，也没有工具调用或额外修复请求。直接使用 URLSession，不引入 SDK 重试；鉴权 challenge 不追加其他凭据，拒绝重定向。

默认截止 30 秒，保存时验证有限值及 5–600 秒；从实际派发覆盖上传、响应头、完整 body 和文本有效性校验，排队等待由队列负责。响应上限 1 MiB，可靠声明长度先拒绝，未知长度逐块在追加前限制。原文和有效输出上限各为 256 KiB UTF-8，提示词上限 64 KiB。输出须为 Chat `choices[0].message.content` 的非空字符串，拒绝无效 UTF-8、不可用控制字符和明确被截断／过滤的内容。鉴权、配额、限流、不兼容、空结果、无效结果、大小限制、网络、ATS、超时与取消各有原因；不展示服务商原始错误体。

超大非 2xx 错误体仍触发早期取消和缓冲护栏；终态保留响应头已知的鉴权、限流、不兼容或服务失败原因。取消导致正文不完整的 429 只能报告限流，不能推断配额。正常有界且完整的 429 错误体仍可区分配额。

## 设置和界面

`PolishConfiguration` 默认关闭，以共享服务 UUID 和独立模型保存角色。一个完整内置默认提示词可以全量编辑；`customPrompt == nil` 表示采用当前默认，升级随内置默认更新。已保存自定义保持原样。`restoreDefaultPrompt()` 清除自定义，保存后恢复当前默认；没有模式或模板框架。

`ServiceSettings.saveService(_:newKey:credentials:)` 可独立新增或编辑共享服务，不改转写角色选择与截止。它和既有 `saveTranscriptionService` 复用凭据原子提交：先写全新 slot，原子配置引用是提交点，清理前回读确认无人引用。旧配置／legacy service UUID slot 和现有转写 API 保持兼容。

`PolishSettingsWindowController(settings:services:credentials:client:configurationChanged:)` 提供 `showSettings()`。共享服务和润色角色有各自保存按钮，避免一次操作出现跨文件部分保存而难以区分。界面含总开关、服务选择／编辑、独立模型／截止、完整文本编辑器、当前默认恢复、删除密钥和数据去向说明。已有密钥不回填；新密钥空白保留。保存成功后 `configurationChanged` 通知 App／队列重新检查仍未发出的有效工作。

服务菜单直接创建 `NSMenuItem`，每项保存服务 UUID 或明确的未选择／新增身份，不由名称或原数组位置推断。合法服务可同名，也可与特殊项显示同名。提示词编辑器记录默认／自定义来源；保存其他参数不会将恰好等于当前默认的自定义改为默认。用户编辑转为自定义，仅显式恢复默认清除该来源。

## 已执行检查与后续验收

2026-10-03 在本机 arm64 Swift 6.2.3 执行 `swift build`（含独立 AppKit 界面）、`swift test` 和 `bash Scripts/build-app.sh release` 均返回 0，测试为 67 tests／4 suites 通过。release 产物是本机构建与开发签名检查，不是正式签名公证或首启验收。新增 15 个润色测试使用公开角色入口、fake API key、真实 URLSession 与仅绑定 127.0.0.1 的受控 HTTP 服务；独立解析实际 JSON，覆盖请求内容、配置晚绑定／在途快照、缺配置等待、无鉴权、发送前持久化失败、鉴权 challenge、404／429 错误分类、无效文本、大小限制、真实慢 body 截止取消、手动取消、重定向，以及 timer 回调尚未运行时的到期结果拒绝。共享服务变更使用真实文件权限失败与凭据边界失败，重新加载配置后发 HTTP 验证地址／凭据仍成对；既有转写测试保持通过。

声明超大响应的真实 HTTP 检查曾只发头而在本机 3 秒内没有观察到终态；保留相同头并发送 512 字节前缀后触发声明长度拒绝与 socket 关闭。最终检查发送的前缀远小于 1 MiB，不能由正文累计护栏产生该失败。该现象不证明所有系统上的 URLSession 头交付时机。

同日独立 review 后完成三项 P2 修复。新增真实 HTTP 回归先失败，再通过，验证超大 403／429／404／500 保留已知原因且实际断开连接；2xx 超大体仍报告大小限制。隐藏 AppKit 检查编译原生产界面文件，仅在同文件扩展中暴露不会激活窗口的加载包装入口：驱动真实菜单／按钮／文本编辑通知，重新读取保存配置，再通过公开客户端发真实 loopback HTTP。同名服务与特殊项撞名检查从错误保存／错误请求变为正确 UUID 或等待且 0 请求；默认来源、自定义恰等默认、编辑和恢复对照均通过。检查使用禁止激活的独立进程、透明度为 0 的窗口，断言所有窗口未显示；没有启动生产 App、麦克风、TCC 或真实凭据。修复后 `swift test` 返回 0，68 tests／4 suites 通过。该隐藏对象检查验证控件操作和保存行为，不是界面视觉或跨 App 实机验收。

本切片尚未接入 App 菜单与队列，因此没有验证共享默认 3 槽位、FIFO／焦点保护下的原文失败候选、音频／原文／润色加密历史、仅重润色不改已上屏、自动发送时间窗或重启恢复清单。界面实际显示、真实 BYOK 效果、TCC／ATS／LAN 授权、硬件与正式包首启均未执行，不能从编译或 loopback 检查推定通过。

协议依据：[Chat completion](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)；取消依据：[URLSession 响应取消](https://developer.apple.com/documentation/foundation/urlsession/responsedisposition/cancel)。
