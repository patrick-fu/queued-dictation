# 跨 App 交付实现切片

对应 #27 的独立交付适配器、两种目标模式及设置窗口。尚未接入 AppDelegate／菜单入口；本次不宣称 #27、原生兼容矩阵或发布验收完成。

## 接线契约

- `DeliveryConfiguration(mode:)` 默认 `recordingTarget`。独立 `DeliverySettings(file:)` 加载／原子保存 JSON；缺文件使用默认，损坏或未知模式报错且保留原文件。
- `CrossAppTextDelivery(configuration:)` 继续满足既有 `TextDelivering`。App owner 在创建录音模型前加载设置；加载失败显示原因，并设置 `automaticDeliveryEnabled = false`。手动插入与主动复制仍可取用。
- `DeliverySettingsWindowController(settings:delivery:)` 是独立 AppKit 设置窗口。用户调用 `present()` 才激活窗口；保存成功才改变适配器配置，失败保持上一有效模式。坏配置暂停自动上屏，用户重新选择并成功保存后解除。
- `captureTarget()` 冻结每段开始录音时的模式；之后 `updateConfiguration(_:)` 不追溯已有 token。默认模式必须当时有可可靠观察的目标；当前光标模式当时可没有输入框，等 `deliver(_:to:)` 真正被 FIFO 队头调用时才捕获。
- 每个 token 只尝试一次交付；成功、待手动或写回不确定后均拒绝再次自动使用。调用方按既有协议 `releaseTarget(_:)` 释放目标。FIFO、逐段手动插入／外部粘贴确认及重启恢复仍由队列核心负责；适配器不绕过其门禁。
- App 的条件检查应定期读取 `accessibilityAuthorized`。观察到撤销就使已有录音时目标失效并移除旧监听，重新授权只允许新捕获目标；未观察到的授权短暂变化不应当作已覆盖的实机证据。
- `currentInputScreen: NSScreen?` 是供带教已有 seam 使用的本地只读来源，只查当前普通可编辑目标的窗口 AX 几何，不读正文或屏幕像素。按菜单栏屏幕原点转换坐标，取窗口重叠面积最大的屏幕；权限、安全输入、几何、焦点身份不足或并列均返回 nil，交由带教浮窗沿用上次屏幕。这个补充以构造坐标检查原点、上下／左右屏幕、并列与未知几何；真实 AX 多屏映射仍待主线实机检查。

## 目标与写入守护

原生候选来自当时前台 App 的 AX 聚焦控件，要求普通文本区／文本框、启用、非安全文本子角色、系统安全输入未启用、选区文字可写，并能读取一致的正文、字符数、选区及所选文字。属性类型、范围、字符数或所选文字与正文不一致均放弃自动目标；正文上限 1 MiB。捕获信息只在本机内存，等待快照仅保留正文 SHA-256 与 UTF-16 选区，不写普通配置、不送模型、不导出。

默认目标保存 App PID、窗口和控件身份；监听焦点、窗口、正文、选区与销毁通知，并观察 App 激活和用户键盘／鼠标输入。捕获期间使用输入代次保护，不能把事件早于 token 入表的空隙当作未编辑。每次交付和真正写入前核验同一可写聚焦目标、同一正文与选区；曾失焦、关闭、用户输入、移光标、不可读／只读、安全输入或权限撤销均保守待手动，不自动激活目标 App。

写入使用 `AXSelectedText` 替换选区，随后读回完整预期正文、选区和目标身份。调用错误、报告成功却没有效果、选区不符、读回失败、写入间焦点／权限／安全输入变化等均为 `uncertain`；没有第二种写入方法、自动补写或重播。当前同步接口没有 Cmd-V 延迟粘贴路径。

已验证的系统 A 插入只推进仍有效、同控件／窗口且同一旧快照的等待目标。正文与选区通知只在 0.5 秒内、每次写入各一次的限额内且匹配预期新快照时归因；超时、额外、不能匹配或用户输入继续使 B 失效。晚到通知和真实目标 App 的事件顺序需要实机验证，有限归因不是全平台成功证明。

AX 对每个实际使用对象设置单次 0.25 秒消息超时。这个值不能证明累计主线程时延、录 B 的 500 ms 指标或停滞目标处理通过；目标 App 可在查询和写入之间继续处理自己的输入，原生 AX 没有跨 App compare-and-set 的原子承诺。

## 剪贴板、撤销与富文本

自动插入和手动“插入当前光标”使用上述直接选区写入，完全不读取、暂存或恢复通用剪贴板，因此没有用旧剪贴板覆盖等待期间／交付时新复制内容的路径。用户主动复制才写入 `NSPasteboard.general`。没有凭固定延迟或 paste 调用完成宣称剪贴板／上屏成功。

没有通过整篇 `AXValue` 改写来支持控件；替换选区的真实撤销粒度、富文本格式以及浏览器脚本事件均需目标 App 实测。属性或可靠监听不可用返回手动，写入是否成功不能确认返回不确定。不能因这些退路静默缩减核心 TextEdit、Safari／Chrome textarea 和 contenteditable 的验收承诺。

## 本次实际检查

- 首条检查在适配器接口不存在时编译 red；实现后，真实独立 `NSTextView` 中仅替换选区、保留 UTF-16 光标，并保留等待中新复制的 named `NSPasteboard` 内容及变更序号。
- 捕获期用户输入的早期实现出现 2 项行为 red；输入代次保护后 green。初始查询返回后用户编辑的早期实现也出现 2 项 red，实际文档成为“用户编辑口述”；写入前最终核验后保留“用户编辑”并返回手动。
- 观察到权限撤销后再授权的早期实现出现 3 项行为 red，旧 token 写入“旧结果”；修复后旧结果待手动，新捕获可交付。
- 受控检查覆盖模式冻结／开始时无当前目标、12 种默认守护变化、系统 A→B 与后续用户修改、延迟和重复通知、8 种写回故障、不确定／成功 token 不重播、手动当前插入、主动复制、监听失败、设置重载／未知模式保留原字节、真实只读目录保存失败。
- 检查只通过可控 AX／焦点／时间外部边界操作构造的独立文档与 named 剪贴板；没有读取用户窗口、使用通用剪贴板、改权限、合成键盘事件、读取生产凭据或上传用户音频。

初次冻结提交 `e003295` 的 `swift test --filter CrossAppDeliveryBehaviorTests` 为 15 tests／1 suite，exit 0；`swift test` 为 98 tests／6 suites，exit 0；`swift build -c release` 与 `git diff --cached --check` 均 exit 0。原始日志随本轮交付附带；这些结果不替代 App 接线后的录音事件→服务→FIFO→真实外部目标集成。开发主机为 macOS 26.6.2（25G83）、Apple Silicon arm64、Apple Swift 6.2.3；arm64e-apple-macos14.0 是部署目标。

## 审查后的原生边界修复

原生本地事件监控曾把本 App 任意 mouseDown 算作目标输入。隐藏且不能成为 key／main 的非激活面板收到本进程生成的点击时，输入目标、正文与选区仍相同，却由成功交付变成待手动。现只排除属于 `NSPanel`、带 `nonactivatingPanel` 且 `canBecomeKey`／`canBecomeMain` 均为 false 的本地鼠标按下；键盘、普通窗口、可聚焦面板、无此样式的面板仍使目标失效。全局输入、App 激活及实际 AX 焦点／正文／选区守护保持，排除面板点击不屏蔽真正的目标变化。

`AXNumberOfCharacters` 原先用 `NSNumber.intValue` 比较，错误接受了 Boolean 与截断后匹配的小数。依据 SDK 声明的 `CFNumberRef` 合同，现先核对真实 CF 类型，再要求完整数值有限且等于正文的 UTF-16 长度；合法整数值（包括数值为整数的 CF 浮点数）、空文档与 emoji 长度保留。Boolean、1.5／2.5、小数、NaN、无穷及错误字符数不产生自动目标或写入。

复用原审查探针的实际 local AppKit dispatch 路径，隔离替换全局监控及通知中心；窗口始终隐藏、不成为 key、不激活 App，没有向 OS 或用户 App 派发事件。基线的非激活面板场景为 callbacks=1／manual／原文不变；修复为 callbacks=0／delivered／“原输入口述”，普通窗口鼠标与面板键盘对照继续 callbacks=1／manual。原生读取方法的可控 AX 边界检查由 4 个畸形字符数被错误接受变为全部拒绝，权限撤销与安全输入继续拒绝；它们不证明实际 TCC、用户焦点或跨 App 矩阵通过。

新增公开适配器→实际独立文档回归包括 8 个本地输入场景及 11 个字符数场景。`swift test --filter 'nativeLocalInputFiltering|nativeCharacterCountValidation'` 与相同 filter 的 `swift test -c release` 均为 2 tests／19 参数场景、exit 0；release 检查同时构建生产 App。两份隔离原生探针编译均 exit 0，运行由基线 exit 1（本地点击 1 处／畸形字符数 4 处失败）变为修复后 exit 0。`git diff --check` 通过。没有重复既有模式、prewrite／readback 消融或整套旧检查；当前完整整合仍由主线验收。

| 必需原生范围 | 本切片证据 |
| --- | --- |
| TextEdit 普通文本 | 未执行真实 AX 交付；只构建生产机制与受控文档检查 |
| Safari textarea／contenteditable | 未执行；需属性、通知、两模式、剪贴板／撤销逐项实测 |
| Chrome textarea／contenteditable | 未执行；需属性、通知、同步读回与富文本实测 |
| 微信、VS Code 编辑区 | 未执行；记录实际版本及自动／手动结果，不能推定兼容 |
| 跨显示器、全屏／Space、实体 Fn／组合键 | 未执行；监听 keyDown 与 Fn flagsChanged 分开，不推定组合键已被系统消费 |
| macOS 14 最低版本、当前正式系统、Apple Silicon | 本机编译部署目标 macOS 14 不等于最低系统实机验证 |

## 原生依据

[Apple AX 选区文字](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)、[选区范围](https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute)、[写入属性与错误](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)、[对象消息超时](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)、[AXObserver 注册](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)和[事件监控](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)用于原生机制约束。

[WebKit 的 macOS AX 实现](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/mac/WebAccessibilityObjectWrapperMac.mm)与[Chromium 的 AX 控件实现](https://github.com/chromium/chromium/blob/main/ui/accessibility/platform/ax_platform_node_cocoa.mm)只用于核对运行时能力查询与选区替换路径；源码能力不证明某个安装版本／控件或其通知与撤销通过。实现复用本仓库已有 TextEdit 交付行为，不并入第三方 GPL 源码。

屏幕映射依据当前 SDK 对 AXPosition／AXSize 的点坐标定义及 [Apple NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens)：第一个屏幕是含菜单栏的原点屏幕，不能用活动窗口的 `NSScreen.main` 代替坐标原点，也不缓存显示器列表。
