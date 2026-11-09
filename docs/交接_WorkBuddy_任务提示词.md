# WorkBuddy 接管任务提示词（直接整段复制给 WorkBuddy）

你现在接管一个已经在开发中的 macOS 原生 App 项目。你的前任（Antigravity 里的一个会话）额度用尽下线了，你必须**先读本文档再动手**，不要凭猜。

---

## 一、你是谁、你要干什么

你是这个项目**唯一的执行开发**。目标只有一个：把下面「待办」里的东西真做完，每次回一行结果 + commit hash。
你**不是**项目经理，不要写计划书、不要做方案汇报；能直接改代码、编译、跑测试，就立刻做。

## 二、项目在哪（必须记死）

- 项目根目录（含 .git）：
  `/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro`
  这是**外置移动硬盘**上的路径（卷名就叫「摄影师工具箱128GB」，中间有个中文空格，命令里记得加引号）。
- Swift 源码包：`FCPXStudioNative/`（SwiftPM，37 个 .swift 文件 / 约 21000 行，含 Models、Views、Sockets，以及 `Resources/core/*.py` 的 Python 侧）
- 打包好的两个 .app 都在项目根目录：
  - `FCPX Studio Pro R2.app` —— **新包，给用户测的，可以改可以重签**
  - `FCPX Studio Pro.app` —— **用户手上的旧包，绝对不许覆盖、不许删除**
- 问题清单台账：`review.md`（258 行，57 条可核对条目，第 1、2 轮整改都已记在里面）
- 历史进度：`03_项目进度总清单.md`

## 三、项目现在是什么状态

- 技术栈：Swift + AppKit（纯原生，不用 SwiftUI 做主界面），Python 侧资源在 `FCPXStudioNative/Sources/FCPXStudio/Resources/core/`
- git 当前 HEAD：`ced8633 fix(teamsync): TR-005 add real startServer entry`，工作区干净（0 个未提交文件），**全部未 push**
- `FCPX Studio Pro R2.app` 里已经是含最新修复的二进制：3343968 字节、sha256 前 8 位 `3798a382`、已 ad-hoc 重签、`codesign --verify --deep --strict` 零报错
- 项目内嵌便携 Python：`FCPX Studio Pro R2.app/Contents/Resources/python_bundle/bin/python3`（3.14.6 + psd_tools 1.24.0，实测可用；系统 python3 没有 psd_tools）

## 四、环境铁律（前任踩过的坑，你照着做能省几小时）

1. **编译必须外置 build-path**，不要在外置盘直接构：
   `cd FCPXStudioNative && swift build -c release --build-path /tmp/fcpx_wd`
   在外置盘直接 build 会报 `disk I/O error: unable to attach DB`。
2. **这块盘的 unlink 有毛病**：`rm` 删 `.git/index.lock` 删不掉，会报 `Cross-device link (EXDEV)`。
   正确姿势是同卷改名：
   `python3 -c "import os;os.rename('.git/index.lock','.git/index.lock.bak_1')"`
   把它改名到 `/tmp` 也一样报错，必须留在同一卷。
3. **绝对不许 `mv` 项目根目录或把它整体 rename**。前任有一次审计脚本把整个项目根改名成 `.Test_bak_日期`，差点出事。要试危险操作，先 `cp -a` 到 `/tmp` 的副本里试。
4. **换过二进制必须给 .app 做包级重签**，否则系统直接 SIGKILL（`Taskgated Invalid Signature`）：
   ```
   codesign --force --deep -s - "FCPX Studio Pro R2.app"
   codesign --verify --deep --strict "FCPX Studio Pro R2.app"   # 必须零输出
   ls "FCPX Studio Pro R2.app/Contents/_CodeSignature/CodeResources"  # 必须存在
   ```
   只签内层二进制不签外层，会报 `code has no resources but signature indicates they must be present`，一样被系统杀掉。
5. git 提交纪律：一个模块一个 commit；一段改动超过 10 分钟没完成，先 `wip(段名): 中途存档` 提交（消息带 `[skip ci]`，不编译也要提交）；任何时刻未提交文件不超过 5 个。
6. **不要 push、不要改 git 历史**（用户没授权）。
7. 用户正在用这台机器剪片时（Final Cut Pro 在跑、键盘空闲时间只有几秒），**不要启动 App 抢焦点**，只做只读的代码核查和编译。

## 五、前任已经做完的，不要重做

- 第 1 轮：12 个致命 + 45 个严重全部修完（`f4a3244`、`6068266`、`a00e64b`、`e071ae8`）
- 第 2 轮 97 条（UI-G001~G071、UI-O001~O026）分 A/B/C/LK/CS/O 六段落地（`ebbb7ca`、`3f7b688`、`2f1b62e`、`183680c`、`dede7da`、`0da8075`）
- 用户实测反馈的 4 个新问题（`a3f0d5f`）：
  TR-001 卡片容量徽章永远显示「计算中…」（`ResourceCardView.swift` 三分支：先读缓存 → 现场算 → 1.5 秒后强制出结果，算不出显示 `--`）
  TR-002 三点菜单改为「用 Apple Motion 打开」并真调 `NSWorkspace.shared.open`（`AssetHubView.swift` `onCardDesignerMenu`）
  TR-003 卡片三套配色打架（`calibratedRed`/`calibratedWhite` 清零，改用 `DesignTokens.ColorToken`）
  TR-004 资源库瘦身支持多选 + 全选（`CleanerDashboardView.swift` `allowsMultipleSelection = true`）
- G012 商业授权层已**整套删除**（`e4e2d82`，`Models/LicenseManager.swift` 已不存在）
- TR-005 团队同步 52888 端口从不监听：已补 3 处 `startServer()` 真调用 + 顶部「▶️ 启动局域网监听 / ⏹ 停止局域网监听」按钮 + 徽章三态（`ced8633`）

以上**只做回归验证，不要重新实现**。

## 六、你要做的（按优先级，逐条做完回我）

### P0 · 52888 端口真机验证（唯一卡住的验收项）

TR-005 的代码和打包都完成了，但**没有人实测过端口是否真的起来**。你要：

1. 启动 `FCPX Studio Pro R2.app`（用户没在用机器时才能起）
2. 进「团队同步」看板，找到「▶️ 启动局域网监听」按钮点一下
3. 跑 `lsof -nP -iTCP -sTCP:LISTEN -a -p <该App的PID>`，确认出现 `52888`（若端口被占会降级到随机端口，此时把真实端口报出来）
4. 再点「⏹ 停止局域网监听」，同样命令确认端口消失
5. 把这两次的 `lsof` 原始输出贴回来

判定标准：启动后能查到监听、停止后查不到，徽章跟着变，这就算通过。

### P1 · 剩下 10 项「必须真机确认项」里你能自测的

前任已关掉 3 项（双管道死锁、冷启动不同步 spawn python、干净机无 python3）。剩下这些里，**能靠截图判定的都归你**：

- 窗口缩到 1000pt 以下，三段控件是否对撞、资源卡是否重排（注意窗口 `minSize` 是 1000×680，如果缩不下去，直接判定该项销项并说明）
- 损坏卡 / 异盘卡点 toggle 是否真弹出说明框
- 乐观态「已恢复在线 → 部分损坏」的窗口持续多久
- 画布能否拖到完全不可见、有没有复位按钮；对比模式右板是否真的不可交互
- 看板高危动作（点卡片即重隔离 / 一键隔离自愈 / 单项搬家）是否**没有**确认弹窗
- TeamSync 徽章在服务未启动时是否还亮绿灯（这条和 P0 一起做）
- FCPX 运行时 trash Render Files 是否报错崩溃；`.disabled` 改名后重启 FCPX 是否真的不加载

每条都要**截图 + 一句结论**（通过 / 不通过 / 销项）。用户明确要求过「看截图不能只看代码」。

### P2 · 第 3 轮：清 `review.md` 里还挂着的条目

打开 `review.md`，把所有标着「未修 / 未验 / 存疑」的条目挑出来，逐条判定：
真没修的修掉；判定是误报的写清证据（文件 + 行号 + 为什么不是问题）。

### P3 · 包体积（先别动，等用户拍板）

`FCPX Studio Pro R2.app` 总共 146MB，其中 `python_bundle` 占 140MB（含 63MB 的 scipy）。用户原则里有「程序不能太大」，但砍 scipy 会牺牲描边/投影/渐变的高保真渲染。**这条等用户说砍再砍，你别自己决定。**

## 七、禁止事项

- 不许自己宣布「可以发布」，不许把致命问题降级成一般
- 不许改 git 历史、不许 push
- 不许覆盖 `FCPX Studio Pro.app`（旧包）
- 不许 `mv` / rename 项目根目录
- 不许只改代码不给验证：改完必须编译（0 error）+ 说明怎么验的
- 不许「出计划不出手」：收到任务就直接开工，不要先写方案再等确认

## 八、回复格式

每完成一段就回**一行**：`段名 完成，commit <hash>` 或 `段名 卡住：<具体原因>`。
不要贴大段代码，不要复述我给你的要求。

---

开工第一步：先 `cd` 到项目根，`git log --oneline -1` 和 `git status --porcelain` 各跑一次，把当前状态回我一行，确认你看到的世界和我描述的一致。
