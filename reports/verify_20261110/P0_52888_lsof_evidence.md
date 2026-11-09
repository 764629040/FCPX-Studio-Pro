# P0 · 52888 端口真机验证 · 原始输出与截图索引

- 时间：2026-11-10 01:08–01:33 GMT+8
- 执行：WorkBuddy（接管会话）
- App：`FCPX Studio Pro R2.app`，PID 59827
- 二进制：3343968 bytes / sha256 `3798a382…` / `codesign --verify --deep --strict` 零输出
- 验证命令：`lsof -nP -iTCP -sTCP:LISTEN -a -p 59827`

## A. 监听态（App 启动后自动拉起；以及点击「▶️ 启动局域网监听」之后）

```
$ lsof -nP -iTCP -sTCP:LISTEN -a -p 59827
COMMAND     PID    USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
FCPXStudi 59827 mrhuang    4u  IPv4 0x7f01d0e0c2228b94      0t0  TCP *:52888 (LISTEN)
```

重新启动后（FD 由 `4u` 变 `3u`，证明是新建 socket，不是旧 fd 残留）：

```
$ lsof -nP -iTCP -sTCP:LISTEN -a -p 59827
COMMAND     PID    USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
FCPXStudi 59827 mrhuang    3u  IPv4 0x2baa7a4358d74bfa      0t0  TCP *:52888 (LISTEN)

$ lsof -nP -iTCP:52888 -sTCP:LISTEN
COMMAND     PID    USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
FCPXStudi 59827 mrhuang    3u  IPv4 0x2baa7a4358d74bfa      0t0  TCP *:52888 (LISTEN)
```

## B. 停止态（点击「⏹ 停止局域网监听」之后）

```
$ lsof -nP -iTCP -sTCP:LISTEN -a -p 59827
（stdout 为空，exit 1 —— 该 PID 已无任何 LISTEN 套接字）

$ lsof -nP -iTCP:52888 -sTCP:LISTEN
（stdout 为空，exit 1 —— 端口 52888 无监听）
```

## 徽章 / 按钮三态（截图硬证据）

| 截图 | 徽章 | 按钮 |
| :--- | :--- | :--- |
| `02_teamsync_listening_green.png` | 🟢 局域网监听中: 端口 52888 | ⏹ 停止局域网监听 |
| `03_teamsync_stopped_gray.png` | ⚪ 未开启局域网监听 | ▶️ 启动局域网监听 |
| `04_teamsync_restarted_green.png` | 🟢 局域网监听中: 端口 52888 | ⏹ 停止局域网监听 |

重启后雷达表出现本机 peer `192.168.1.7:52888`（在线编辑），Bonjour 广播同步生效。

## 判定

**通过**：启动后能查到监听、停止后查不到、徽章与按钮标题三态同步变化。

## 观察事实（非缺陷判定，供裁决）

`TeamSyncDashboardView.swift:573-586` 的 `viewDidMoveToWindow()` 在 `!isListening && lastServerError == nil` 时无条件调用 `startServer()`，因此 App 一启动 52888 即 LISTEN，不需要用户点按钮，按钮初始为「⏹ 停止局域网监听」。本轮按「先停止 → 再启动」完成双向验证。
