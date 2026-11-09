# TR-006 真机验收：52888 端口启停（拒绝自动启动）

- 时间：2026-11-10 02:11~02:17 GMT+8
- 被测包：`FCPX Studio Pro R2.app`（已换入新二进制并重签）
- 进程 PID：73668
- 二进制：3344984 B / sha256 前 16 `2cc3518d056d0a1b`
- 编译：`swift build -c release --build-path /tmp/fcpx_wd --disable-sandbox` → `Build complete! (29.89s)`，**0 error**（1 条既有 deprecated warning：`AudioManager.swift:165`）。
  注：不带 `--disable-sandbox` 会报 `sandbox-exec: sandbox_apply: Operation not permitted`（接管会话嵌套沙箱，非源码问题）。
- 签名：`codesign --force --deep -s -` → `codesign --verify --deep --strict` **零输出**（RC=0），`Contents/_CodeSignature/CodeResources` 存在（976308 B）。

## a 重启 App 后 5 秒内

命令：`lsof -nP -iTCP:52888 -sTCP:LISTEN`

原文（02:12:05 / 02:12:06 / 02:12:07 / 02:12:07 / 02:12:08 / 02:12:09，共 6 次采样）：

```
（stdout 为空，exit 1 —— 无任何监听）
```

交叉验证：`lsof -nP -iTCP -sTCP:LISTEN -a -p 73668` → stdout 为空，exit 1，该 PID **零 LISTEN 套接字**。

## b 点「▶️ 启动局域网监听」后

命令：`lsof -nP -iTCP:52888 -sTCP:LISTEN`

原文：

```
COMMAND     PID    USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
FCPXStudi 73668 mrhuang    7u  IPv4 0x695170b3553e705e      0t0  TCP *:52888 (LISTEN)
```

交叉验证：`lsof -nP -iTCP -sTCP:LISTEN -a -p 73668` 同上，仅此一条。端口未被占用，无降级随机端口。
UI：徽章「🟢 局域网监听中: 端口 52888」、按钮「⏹ 停止局域网监听」、雷达出现本机 `192.168.1.7:52888`。

## c 点「⏹ 停止局域网监听」后

命令：`lsof -nP -iTCP:52888 -sTCP:LISTEN`

原文：

```
（stdout 为空，exit 1 —— 无任何监听）
```

交叉验证：`lsof -nP -iTCP -sTCP:LISTEN -a -p 73668` → stdout 为空，exit 1，该 PID **零 LISTEN 套接字**。
UI：徽章回落「⚪ 未开启局域网监听」、按钮「▶️ 启动局域网监听」。

## 期望 5：进程退出必须释放端口

换二进制前 kill 旧 PID 59827（当时正监听 52888）→ `lsof -nP -iTCP:52888 -sTCP:LISTEN` 输出 `NO_LISTENER`。
新二进制另在 `main.swift` 的 `applicationWillTerminate` 显式调 `stopServer()` / `stopBrowsing()`，作为内核 fd 回收之外的双保险。关看板/切换窗口不触发。

## 截图（本目录）

| 文件 | 状态 |
| --- | --- |
| `06_启动前_无监听.png` | 进入团队分发看板：⚪ 未开启局域网监听 / ▶️ 启动局域网监听 |
| `07_启动后_52888.png` | 🟢 局域网监听中: 端口 52888 / ⏹ 停止局域网监听 / 本机 192.168.1.7:52888 |
| `08_停止后_无监听.png` | ⚪ 未开启局域网监听 / ▶️ 启动局域网监听 |

## 代码改动（唯一 UI 入口）

- `Views/TeamSyncDashboardView.swift`：删掉 `viewDidMoveToWindow()` 里的无条件 `startServer() + startBrowsing()`；删掉 `refreshData()` 里的兜底 `startServer()`。改完全项目 `startServer()` 实际调用仅剩 `onToggleServerClicked()` 一处（:610），即用户点击按钮。
- `main.swift`：新增 `applicationWillTerminate(_:)` 显式释放端口与 Bonjour 广播。
