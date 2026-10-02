# 发布工具与证据边界

本工具对应 [#35](https://github.com/patrick-fu/queued-dictation/issues/35) 的打包准备切片。[#22](https://github.com/patrick-fu/queued-dictation/issues/22) 中的完整能力、权限、兼容、真实 Fn、BYOK、最低系统和连续录音 P95 门槛仍须在全部切片集成后验收。工具检查通过不表示首版完成，也不关闭 #35。

## 开发构建和公开 CI

```sh
bash Scripts/build-app.sh release
swift test --jobs 2
ditto -c -k --sequesterRsrc --keepParent "dist/Queued Dictation.app" dist/Queued-Dictation-development.zip
bash Scripts/check-release-tools.sh "dist/Queued Dictation.app" dist/Queued-Dictation-development.zip
```

`build-app.sh [debug|release] [output-directory]` 默认写入 `dist/Queued Dictation.app`，保持 ad-hoc 开发签名。指定输出目录时，已有同名 App 会被拒绝；正式工具用这个入口构建独占副本。App 包含 MIT `LICENSE.txt`，当前 `Package.swift` 没有外部包依赖。

CI 在 `macos-15` 构建和运行原有行为测试，复检真正上传的开发 ZIP，再上传带有 development 名称的 artifact。构建、检查均不需要生产签名或公证凭据，也不读取用户音频。GitHub 当前的 [runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 将 `macos-15` 列为 arm64；发布验收仍须记录实际 runner 日志和真实用户硬件，不能用这个标签代替 macOS 14 实机证据。

## Developer ID 签名检查

运行前提交工作树中的全部相关修改。`--identity` 必须明确提供本机公开列表中有效的 Developer ID Application 完整名称或 SHA-1；工具不会猜身份、改钥匙串权限、导出私钥或接受密码参数。`--output` 必须是尚不存在的新目录。App 转换为物理路径时保留全部尾部字符，再拒绝 LF／CR，包括普通符号链接指向的异常物理目录，以免验证错误的邻居 App 或把路径内容当作签名 metadata 新行；仓库经符号链接进入时，发布入口统一使用物理路径比较源码和输出。

```sh
bash Scripts/release-app.sh sign \
  --identity "Developer ID Application: Your Name (ABCDEFGHIJ)" \
  --output "${TMPDIR:-/tmp}/queued-dictation-signed-check"
```

`sign` 从干净源码构建 release arm64 App，使用明确身份、hardened runtime、Apple secure timestamp 和唯一的 `com.apple.security.device.audio-input=true` entitlement 签名。随后检查真实产物的证书类型、Apple 信任链、团队、runtime、timestamp、entitlement、bundle、可执行权限、arm64 架构及 Mach-O 的 macOS 14.0 部署目标。麦克风 entitlement 的依据是 [Apple Audio Input Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)；它不代替 TCC 授权或真实录音检查。

成功输出独立 App 和 `evidence/result.txt`，其中 `result=verified_signature`、`notarization=not_submitted`。这个入口不提交公证，也不生成正式 ZIP。钥匙串阻止签名、secure timestamp 网络失败或产物检查失败都会返回非零；失败阶段与原始本机日志保存在输出目录，不能据此声称正式签名或公证通过。

单独复检可用：

```sh
bash Scripts/verify-app.sh signed "/path/to/Queued Dictation.app"
```

## 公证、staple 和最终 ZIP

此入口会将 App ZIP 上传 Apple。只在全量集成已经可验收、上传已授权且明确提供现有 notary Keychain profile 名称时运行。本切片不创建、枚举或猜测 profile，也不设置生产 CI secrets。

```sh
bash Scripts/release-app.sh notarize \
  --identity "Developer ID Application: Your Name (ABCDEFGHIJ)" \
  --notary-profile "existing-profile-name" \
  --output "${TMPDIR:-/tmp}/queued-dictation-notarized-release"
```

工具先完成同样的签名验证，再用 `notarytool submit --no-wait --output-format json` 上传。成功响应的 submission ID 验证为 UUID 后立即保存为私有的 `evidence/notary-submission-id.txt`，再执行 `notarytool wait <ID> --timeout 20m --output-format json`，分别保留 submit 和 wait 输出。只有 wait 成功且响应和下载日志都确认 `Accepted`，才执行 App `stapler staple`、`stapler validate` 与 `spctl --assess --type execute`。然后重新生成 ZIP，解压实际 ZIP，重新执行以上验证并比较启动二进制，最后输出 `Queued-Dictation-<version>-macOS-arm64.zip`、SHA-256 和 `result=verified_package`。

[Apple 官方公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) 要求 Developer ID、hardened runtime 与 secure timestamp；[自定义流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) 说明 ZIP 本身不能 staple，必须把票据附到 App 后重打 ZIP。脚本会下载 notary log；发布 GitHub Release 前仍须查看其中的 warnings，并完成原生首启和支持矩阵验收。脚本不会创建 tag、GitHub Release 或上传 GitHub 资产。

超时、拒绝、认证失败和 staple／Gatekeeper／ZIP 复检失败均返回非零，并保留 `.work` 与 `evidence`。wait 超时或中断保留已保存的 submission ID 和原退出码；wait 返回 `Invalid` 时尽力下载拒绝日志，下载失败也留具体错误并停止。notary 超时不等于服务取消，脚本不会自动再次提交；用保留的 ID 手动检查既有请求。若提交响应返回前断网或中断，Apple 可能已收到提交而本机尚未拿到 ID，工具不能保证保留这个未返回的 ID，也不会自动重传。只有成功的 `result.txt` 与匹配的正式 ZIP 可作为工具验收依据。

`evidence` 保留源码 commit、公开签名身份、OS／架构／Swift／Xcode、构建和签名检查、notary 返回／日志、staple 与解压检查、二进制／提交 ZIP／最终 ZIP 的 SHA-256。源码在构建或打包期间变化会使工具失败。输出和日志父目录为本机私有权限，App 内部保留正常文件权限，ZIP 保留可执行位。

## 本切片实际检查

2026-10-03，Mac mini `Mac16,10` / Apple M4，macOS 26.6.2（25G83），Swift 6.2.3，Xcode 26.2（17C52）：

- `swift build -c release --arch arm64 --jobs 2`、开发 App 构建与真实 ZIP 往返成功；Mach-O `minos=14.0`、bundle 最低版本 14.0、仅 arm64。
- `check-release-tools.sh` 通过真实文件检查：ZIP 后仍可执行且签名有效；ad-hoc 被 Developer ID requirement 拒绝；修改已密封资源和丢失可执行权限均被拒绝；ad-hoc 身份、缺 profile、已有输出目录在创建或替换产物前失败。
- `swift test --jobs 2` 的 15 项原有录音／加密历史行为检查通过；没有启动 App、录音、触发全局键或调用真实模型。
- 源码 commit `b7cacf5e26141423b90002e7dbb3d87a659d3f5b` 实际运行 `release-app.sh sign` 成功：Developer ID Application 指纹 `B3882D7FBC455D5A8977445ED5D1470EEABC468D`、团队 `9N7UKH59LC`、Apple 信任链、hardened runtime、secure timestamp 和唯一 audio-input entitlement 均通过真实产物检查。签名 App 的 ZIP 往返后同样通过签名检查。
- owner 在签名 App 的隔离副本上做单变量对照：基线完整签名通过；依次仅去掉 runtime、secure timestamp、audio-input，三份副本仍通过普通 `codesign --verify --deep --strict`，但均被正式 verifier 拒绝，并给出对应缺项。这个结果验证三项发布门槛的作用，不替代独立执行者的 review／消融。
- `shellcheck`、`bash -n`、entitlement plist 检查和 `git diff --check` 通过。
- 独立审查后的三个 P2 已修复并做 owner focused 回归：原始 LF 路径签名样本与新增 LF／CR 路径检查均被明确拒绝，正常签名基线仍通过；受控 notary wait 超时／中断保留 0600 的 ID 文件和退出码 124／143，`Invalid` 留拒绝日志，日志下载失败仍保持失败且不出 ZIP；物理／符号链接仓库入口均通过仓库内输出检查。这些 notary／staple／Gatekeeper 结果来自受控工具边界，均不是 Apple 的实际 Accepted 或票据。
- focused delta 发现命令替换剥掉物理 App basename 尾部 LF、可能误验正常邻居的 P2；已用 sentinel 保留尾部字符后检查。复用已损坏的尾 LF App，直接签名验证失败，修复后 verifier 与普通符号链接入口均明确拒绝该物理路径，正常真实签名基线仍通过；公开检查保留这个回归。
- 公证 Accepted、staple、Gatekeeper 正式包和原生首启尚未验证。当前未提供明确 notary profile，未进行任何公证上传。GitHub 托管 CI 尚未运行本改动。

最低 macOS 14 实机、中间系统、发布时最新正式系统完整功能、真实 Fn／外接键盘、焦点写回、多显示器／Space、所选 BYOK、至少 30 轮 A/B 和 P95 数据均不属于上述工具检查的已通过结论。
