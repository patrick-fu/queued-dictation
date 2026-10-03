# 原生首 PCM 验收工具

本工具消费共同 `native-contract-v1.json`。它不会启动 App／监听器／麦克风、生成按键、授予权限、读取真实 Keychain 或用户音频。离线 fixture 只验证工具合同，`native_samples=0`；真实采样和设备声明必须由人工完成。最低系统／完整矩阵、签名公证发布、识别与带教质量另行验收。

## 准备采样包

`WT` 是已集成 Swift 观测与本工具的干净冻结仓库；`R` 是全新绝对临时目录。同一 R 的 build／package／serve 共用 run_id。输出已有 App、旧 ready 或不属于工具的非空目录均拒绝覆盖。下面是后续人工授权的命令；工具离线自测不执行 Swift 构建或签名。

```sh
KIT="$WT/Tools/NativeAcceptance"
python3 "$KIT/native-control.py" build --repo "$WT" --root "$R" --print-command
python3 "$KIT/native-control.py" build --repo "$WT" --root "$R"
python3 "$KIT/native-control.py" package --repo "$WT" --root "$R" --sign-identity '<明确的 Developer ID identity>'
python3 "$KIT/native-control.py" serve --root "$R" --pairs 30 --coach-input-mode text
```

build 固定 release／arm64／jobs2／独立 `R/build`／`-DNATIVE_ACCEPTANCE`；记录 argv、exit、代码 SHA 及真实二进制 SHA。package 使用原 Info.plist／LICENSE／同 bundle ID，注入 `QDNativeAcceptanceRoot` 与 `QDNativeAcceptanceSourceCommit`，Developer ID 使用与生产相同的 hardened runtime／secure timestamp／App/Release.entitlements，并调用原 Scripts/verify-app.sh signed；不公证／发布，不把普通包当采样包。serve 仅绑定 `127.0.0.1:0`，ready 的 URL 固定为 `http://localhost:<port>/v1`，提供固定假模型／一次性本机假 key。ad hoc 的显式identity `-` 只用于 fixture，不能 native PASS。只由人工／CUA打开此采样 App；不能从 shell 启动 GUI。

人工先确认权限、设备和 TextEdit 新空文档，记录精确 OS／Apple Silicon 型号／键盘与 Fn 设置／麦克风／显示器／手势。同一矩阵至少30轮。首次授权、设备变化或睡眠单列，不混入稳定组；不拼不同配置凑30。

## 每轮实体键 H1/H2/H3 → P1/P2/A → B

1. 用实体快捷键录三个不同短句 H1/H2/H3，各自 ASR／polish 即刻完成，三个真实 Coach HTTP 被保持。随后录 P1/P2/A，三个 ASR 保持。声学输入应可区分；相同 PCM digest 或身份不唯一会 invalid，绝不按 HTTP 到达顺序／`segment.wav` 猜 ID。
2. 控制台出现“实际3＋3已收到完整body”后，实体键录 B 约1秒并结束。服务端在收到真正首个成功入流 PCM 事件前不回复这六个请求；然后释放 P1，让 B 先于 P2/A 得到 ASR／polish。
3. 看到“B HTTP已完成”后才打开现有 Queue，实际观察 B 的 `waitingForPredecessor` 和 P2/A 在途。不能在 t0/t1 压力期间扫历史／AES。用人工或 CUA 把观察源放到 `R/operator-evidence/`，用 `native-control.py clock --root "$R"` 保存观察前后同一 mach 时基的 clock_ns、B ID、pair、stage（不能另开 Python 用 time.monotonic_ns；本机3.9为进程相对epoch）。**Queue 可能改变焦点：release-rest 前恢复原 TextEdit 文档及原 caret，不点击另一个插入位置。未恢复可能转 manual，不能冒称自动 FIFO 通过。**
4. 显式提交下列 proof；管理命令只放行自有 HTTP，不操作 App。最早 Coach 必须在默认30秒内排空；ASR60／polish30／Coach30 不延长。超时／取消会失败，不重建槽或自动重试。

```json
{"schema_version":1,"run_id":"<ready UUID>","pair_index":1,
 "history_id":"<status 中 B 的实际 UUID>","stage":"waitingForPredecessor",
 "source":"human","observation_started_ns":0,"observation_finished_ns":0,
 "artifact_path":"operator-evidence/pair-01-queue.png","artifact_sha256":"<真实 SHA256>"}
```

0 是待人工填写的占位，会被拒绝；`source` 可为 human／cua，不能给 synthetic 观察冒名。观察区间须在 B polish 实际响应后、P2/A 实际响应前；时间不得使用墙钟或伪造。`status` 仅用于查看自有控制状态，不是 UI 证据。

```sh
python3 "$KIT/native-control.py" status --root "$R"
python3 "$KIT/native-control.py" clock --root "$R"
python3 "$KIT/native-control.py" release-rest --root "$R" --proof operator-evidence/pair-01.json
python3 "$KIT/native-control.py" checkpoint --root "$R" --pair 1
```

每轮21个真实 POST（7段×3角色）排空后才请求 checkpoint。App 自身还须 ready、无 pending／inflight 才写 public history／queue／exports；5秒未返回则缺证，保留原 request，不盲重试。下一轮从 H1 重新占池，不能把旧 Coach 跨30轮保持。所有请求 body、WAV、response、receive／mapping／response／disconnect 时间与保持事实均保留。

## 收尾与归约

人工／CUA取回真实 owned TextEdit 最终全文为 `document-final.txt`，不得由成功 flags 生成。填写 `operator.json`：schema_version/run_id/evidence_origin=native_physical、physical_input=true、source=human或cua、精确 os_version/hardware_model/architecture=arm64/keyboard/microphone/matrix_id/binding=fn或combination/gesture=holdToRecord或tapToToggle、document_source、attestation_source，以及真实 `attestation_artifact/attestation_sha256`；还需 permissions_authorized_before_sampling=true、sleep_or_device_change=false。未确认不能写 true；fixture 必须明示 synthetic_contract_fixture，不得填写真实设备假声明。

```sh
python3 "$KIT/native-control.py" stop --root "$R"
python3 "$KIT/native-report.py" --root "$R"
```

report 写 `native-report.json` 与 `native-pairs.csv`。核验原始 OS t0→真实成功 yield t1、所有有意义的按下尝试（失败后重试不能被30个成功覆盖；点按只排除有实际录音区间证明的停止键）、真正 HTTP 3＋3 完整 body 的 `[body_complete,response_begin)` 同时覆盖 t0/t1、A 在途、独立时基、0起点 chunk／样本连续性／无队列丢失、源 PCM／public history／导出／上传 WAV 的帧数与 digest、B 待前段源证据、实际文档每标签一次及 FIFO。Carbon Double 与 Swift rounded＋独立 boot offset 只容许可追溯的≤1ns量化差；Fn offset固定0，不改写已记录 t0，不用 callback 延迟拟合时钟。

同矩阵 n≥30，最近秩第 `ceil(.95n)` 个延迟≤500ms且每轮完整才可能 `PASS_NATIVE_CELL`／exit0，仍不是完整 spec 矩阵。已有证据矛盾为 FAIL／exit1；缺证 INCOMPLETE／exit1；合成来源或合成 calibration 只能 FIXTURE_ONLY／exit2且 native_samples=0。普通 b007包、来源／采样模式／签名证明缺失、仅 metadata 宣称3/3、慢／缺失样本、错误帧／摘要、乱序／重复文档均不能通过。

离线定向检查：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/NativeAcceptance -p test_native_contract.py -v
```

只生成少量合成 PCM／schema fixture，真实127控制保持／放行测试也不计作 native采样。`--fixture --pairs 1` 专用于此合同控制，不能作为真实30轮入口。
