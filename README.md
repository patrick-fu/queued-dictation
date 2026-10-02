# queued-dictation

macOS 菜单栏语音输入工具，首版规格见 [issue 22](https://github.com/patrick-fu/queued-dictation/issues/22)。当前已实现录音、加密语音历史和单项 WAV 下载；转写、全局快捷键、自动上屏和带教按后续票实施。

## 构建与运行

需要 Apple Silicon、macOS 14 以上与 Swift 6 工具链。无需第三方依赖或模型服务凭据。

```sh
swift test
bash Scripts/build-app.sh debug
open "dist/Queued Dictation.app"
```

菜单栏 `QD` 提供录音、语音历史和设置入口。首次可以选择「稍后设置」。点击「开始录音」后按系统提示允许麦克风，结束并保存后到历史选择条目、下载音频。麦克风拒绝或撤销时，历史和下载仍可使用。

`bash Scripts/build-app.sh release` 生成 arm64 开发 App。脚本使用本地临时签名；Developer ID 签名、公证与正式发布包由发布票实施，开发包不代表正式安装包验收通过。

## 本地保护与额度

数据目录为 `~/Library/Application Support/QueuedDictation`。音频从第一块落盘开始使用 AES-GCM 加密；历史元数据也加密，独立数据密钥由系统钥匙串管理。录音过程中没有持久明文暂存。缺少密钥或数据损坏会提示错误并保留原文件，不能通过新建密钥自动修复。

默认单段 5 分钟、全本地数据 5 GiB。额度按逻辑字节与实际文件分配空间取较大者计入，加密收尾预留 1 MiB，真实磁盘另保留 64 MiB；触顶停止录音并保留已成功保存的有效音频。主动取消当前录音丢弃当前音频；录完后取消片段保留历史和下载。无音频不创建空条目。

历史读取和录音前按默认 30 天清理已完成或已取消条目；待处理片段不会因此被删除。当前未配置转写，所以新录音保留为待处理。用户主动下载的 WAV 是普通文件，下载位置须在加密数据目录以外。中断录音的恢复清单由后续票实施，现有 active 音频块仍为加密文件。

## 检查与接口

`swift test` 从 `RecordingApplication` 的录音操作入口检查历史、实际 WAV 解码、取消、额度、权限变化、密钥丢失和文件保护，使用可控音频来源与钥匙串边界，不需要用户录音或凭据。CI 构建开发 App 并执行相同行为检查。

真实麦克风、TCC 拒绝／撤销／恢复、macOS 14 实机、原生窗口布局和正式签名包需另行实机验收。自动化合成音频不能替代这些证据。

后续模块接入约定见 [录音与历史接口](docs/implementation/recording.md)。源代码采用 MIT 许可证。
