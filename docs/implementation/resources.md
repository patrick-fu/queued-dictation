# 资源配置与未发时间窗模块（#29）

本切片新增独立数值配置、现有额度类型转换、纯时间窗判断及 AppKit 设置窗。它尚未接入录音模型、请求调度、加密段级元数据或 App 菜单，不代表 #29 整票完成。行为依据是[父规格 #22](https://github.com/patrick-fu/queued-dictation/issues/22) 的配置预算与时间窗规则。

## 配置与保存

`ResourceConfiguration` 只包含以下六项。持久化时长使用秒、空间使用 `UInt64` 字节，UI 显示分钟、小时、MiB 和 GiB。

| 公有字段 | 默认 | 合法范围 |
| --- | --- | --- |
| `maximumPendingSegments` | 20 | 整数 1–100 |
| `maximumPendingDuration` | 1800 秒 | 60–7200 秒，有限数值 |
| `maximumPendingAudioBytes` | 268435456 字节 | 67108864–2147483648 字节 |
| `maximumRecordingDuration` | 300 秒 | 60–3600 秒，有限数值 |
| `maximumLocalBytes` | 5368709120 字节 | 1073741824–107374182400 字节 |
| `automaticSendingWindow` | 86400 秒 | 3600–604800 秒，有限数值 |

范围端点有效；合法 `TimeInterval` 小数和整字节尾数原样保存。无效值明确抛 `ResourceSettingsError`，不截断、不限制到最近端点。转写整体截止、主池并发和润色／带教预算沿用各自已有设置，本模块不另建请求池或复制这些配置。

`ResourceSettings(file:)` 接受本地 file URL，`load()`、`save(_:)` 和 `validateConfiguration(_:)` 在主 actor 上调用。首次缺文件返回默认配置，不创建文件。损坏 JSON、缺字段、非法数值、读取权限失败均抛错并保留原文件，不能由调用者用 `try? load() ?? ResourceConfiguration()` 静默运行。

系统 `JSONDecoder` 可能把接近整数的原始小数先舍入为整数。`load()` 在系统确认 JSON 语法与字段类型后，用内部 `ExactIntegerJSONFields.areIntegers(_:in:)` 核验三个整数字段的原始 token，再做既有范围校验。该 helper 只定位具名根字段，以原始尾数和指数判断数学整数性，不经过 `Double` 或 `Decimal`；转义键按系统字符串解码，嵌套或字符串中的同名内容不参与配置。合法 `1.0`、科学计数整值和超出 Decimal 精度的全零小数尾数仍可读取，保存仍是原来的数值 JSON。时间字段继续采用 `TimeInterval` 的有限 `Double` 与范围约定。

保存先校验全部值，在同目录创建 0600 staging 文件并完成权限设置，然后以 `rename` 原子替换。目录为 0700，既有目录缺少所有者读写执行权限时拒绝保存，不恢复被用户收回的写权限。所有可能抛出的权限／写入步骤均在替换之前；保存失败不替换先前配置，替换成功后不再执行可能报告保存失败的工作。该文件只有数值，无正文、音频、提示词、凭据或段级状态，不重复加密内容存储。

## 核心接入接口

```swift
let resources = ResourceSettings(file: applicationDataDirectory.appendingPathComponent("resource-settings.json"))
let configuration = try resources.load()
let queueLimits = try configuration.queueLimits
let recordingLimits = try configuration.recordingLimits
```

两个转换属性复用 `QueueLimits` 和 `RecordingLimits`。它们采用 throwing getter，手工构造的非法配置也不能绕过校验。运行时调低额度后的拒录、录中截停、已有占用与真实磁盘余量检查，仍由录音／存储核心在后续接线时执行；本模块不会删除或淘汰任何数据。

## 自动发送时间窗

```swift
let expired = try configuration.isAutomaticSendingExpired(
    recordingEndedAt: actualRecordingEnd,
    renewedAt: persistedRenewalAnchor,
    now: currentTime
)
```

判断只使用 `renewedAt ?? recordingEndedAt`。超过时间窗才过期，恰好到达边界仍有效；默认 24 小时即录音结束后第 86400 秒仍有效，第 86400.5 秒已过期。主动恢复的显式锚点开启新窗口，再次超过同样暂停。非有限日期或时间差明确抛 `invalidWindowAnchor`，不默许发送。

`recordingEndedAt` 必须来自录音实际结束事件，不能传历史 `recordedAt` 的开始时间，也不能把音频帧时长当作实际结束事件的证明。调用者须先成功保存加密段级结束／恢复锚点，再以该锚点判断；原录音时间保持不变。本模块不保存锚点、不构造恢复清单，也不重新计时已发请求的完整截止。

该判断只是未发有效工作的一个门禁。后续接线必须同样检查转写、未发润色和未发带教；带教暂停不能阻塞主交付，主工作暂停不能静默跳过 FIFO。已有失败、超时或不确定尝试不因改设置、联网或窗口恢复自动重发，仍须核心核验当前尝试及显式处置。

## 设置窗接入

`ResourceSettingsWindowController(settings:configurationChanged:)` 是独立 AppKit 窗口。App 可懒创建并持有同一配置对象，主动菜单入口调用 `present()`；成功保存后才调用注入的主 actor callback，供核心重新加载。窗口不直接操作录音、请求、钥匙串或段级历史。

六个字段标明单位与范围，显示当前有效值及失败原因。坏文件显示空字段和错误，不假装加载默认值。未保存编辑不会因为重复打开菜单被悄悄替换；“重新读取”是显式操作。未编辑时长保留原始秒数，避免除法回显后再乘法改变有效小数；空间按精确十进制换算，只有完整且可由 `UInt64` 表示的字节才保存。手动 `present()` 可激活 App；本切片的隐藏控件检查未调用该方法。

## 实际检查与未完成项

- 初始切片 `ff6fa47` 的 `swift test --filter ResourceSettingsBehaviorTests`：exit 0，10 项。真实临时文件检查覆盖保存／重新读取、全部合法端点、20 个非法数值分支、0700／0600 权限、目录只读保存失败与显式再保存、文件无法读取、损坏／缺字段／非法已存值、现有额度转换及严格时间窗边界。先在缺接口、默认权限、非法值覆盖与缺文件读取时取得对应失败，再完成实现。
- 初始切片完整 `swift test`：exit 0，132 项／8 套件，包括既有受控录音性能检查，实际完整保存 491520／491520 帧。`swift build -c release`：exit 0。`git diff --cached --check`：exit 0。
- 隐藏 AppKit 控件实际点击保存后重读：67.1 秒等原始小数保持，MiB／GiB 的单字节尾数完整回显，编辑后转换到确切整字节；分数字节、溢出、非整数段数、NaN、目录权限失败均不覆盖旧文件或触发保存 callback。坏 JSON 显示空字段与错误，未保存不完整修复。两窗口 `isVisible=false`，未调用 `present()`，未激活 App。

审查后的整数读取回归先复现六个近整数／范围边界小数被系统舍入，以及三个超过 38 位精度的同类输入与转义键。独立本机探针证实 `Decimal` 也会吞掉超精度尾数，因此采用上述原始 token 检查。修复后 focused 检查 13 项 exit 0，九个小数和转义键均明确拒绝且错误文件字节不变；两种合法整值表示、时间小数、单字节尾数、嵌套与字符串同名控制均通过真实加载／保存。共享 helper 的 Swift 6 编译及独立探针、`swift build -c release` 和差异检查均 exit 0；系统不接受的默认 UTF-32 BOM 输入明确记录为未满足 helper 前置条件。本次仅复验数值读取相关检查，未重复完整 132 项或受控录音节拍。

运行接线、联网仅续未发工作、Retry-After、实际结束／恢复锚点加密保存、三角色调度门禁、动态额度与真实空间余量，以及菜单和原生交互均未在本切片实现或验收。真实麦克风、TCC、用户配置、生产钥匙串与可见生产 GUI 未操作。
