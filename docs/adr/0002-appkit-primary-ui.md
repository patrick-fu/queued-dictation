# 首版以 AppKit 为主构建原生界面

首版面向 macOS 通用输入框，包含菜单栏、录音胶囊、独立带教浮窗及跨应用输入交互。用户选择以 AppKit 为主构建原生界面，SwiftUI 仅在确有必要时局部使用，例如接入只有 SwiftUI 形式的系统组件；这明确取代此前 SwiftUI 主导、AppKit 补充的候选路线，后续界面实现应保持这一边界。

SwiftUI 局部组件可经原生桥接嵌入，不能因为一个组件使用 SwiftUI 就扩大为整套界面迁移。框架选择不替代对浮窗键盘焦点、全屏／Space、实体快捷键和跨应用写回的实机验收。产品决议见[确定首版 macOS 分发、支持范围与技术方案](https://github.com/patrick-fu/queued-dictation/issues/18)。
