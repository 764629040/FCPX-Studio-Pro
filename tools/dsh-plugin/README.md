# FCPX Studio Pro 审核轮次自动化（DSH 插件）

把每轮重复的手工操作收敛成一条命令。

## 解决什么问题

此前每个审核轮次都要手工完成：

| 手工步骤 | 耗时 | 易错点 |
|---|---|---|
| 重算 30 个受控文件 SHA-256 并写 JSON | 数分钟 | 漏文件、路径写错 |
| 分别跑 macOS 与无 AppKit 两套测试 | 约 3 分钟 | 忘记跑其中一套 |
| 手工记录退出码 | — | 经 tee/管道取到错误码（本项目已犯过） |
| 比对上一轮清单，找出改了哪几个文件 | 数分钟 | 凭记忆遗漏 |

`tools/round.py` 把上述四步合并，一条命令完成。

## 用法

```bash
# 一条命令完成一轮准备：指纹清单 + 双环境测试
python3 tools/round.py all --tag round6

# 只生成指纹清单，并自动对比上一轮
python3 tools/round.py inventory --tag round6

# 只跑双环境测试（macOS + 模拟无 AppKit）
python3 tools/round.py verify --tag round6

# 对比两份清单
python3 tools/round.py diff docs/audit_inventory_20261027_round5.json
```

## 输出示例

```
指纹清单: docs/audit_inventory_round6.json  (30 项)
对比基线 audit_inventory_20261027_round5.json: 相同 28 / 改动 2 / 新增 0 / 移除 0
  改动 gui/canvas_view.py
  改动 tests/test_round4_a12_a17.py

[macos     ] exit=0  ================= 82 passed, 436 warnings in 76.93s ==================
[no_appkit ] exit=0  ============ 80 passed, 2 skipped, 436 warnings in 87.02s ============

综合退出码: 0
```

## 关键设计

**退出码真实性**
退出码直接取自 `subprocess.run(...).returncode`，写入日志末行
`PYTEST_EXIT_CODE=N`。全程不经 `tee` 或管道——项目此前在这里出过错，
工具从结构上消除该风险。

**写入守卫：白名单优先（A-19）**
`_guard_write()` 在每次写文件前校验路径。

第六轮审核指出原实现只用黑名单（硬编码 `/Volumes/NO NAME/128`），
新增只读挂载点或路径绕过即失效。现已改为：

- **主防线（白名单）**：写入必须落在项目根目录内，默认拒绝一切外部路径；
- **辅防线（黑名单）**：保留原只读卷名单作为防御性冗余。

实测 9/9 场景通过，含 `PROJECT_ROOT + "_evil"` 这类前缀混淆绕过。
有一个用例专门用「从未被硬编码过的虚构只读卷」证明白名单生效。

**工具自身受指纹保护（A-19）**
`tools/` 下 5 个文件已纳入 `CONTROLLED` 清单（清单从 30 项增至 35 项）。
理由：`round.py` 能写 `docs/`、能起子进程、能生成清单，是高权限工具；
若自身不受指纹保护，任何改动都无法被发现。

**单卷权威**
清单内 `canonical_path` 只记当前项目绝对路径，`note` 明确写
「不声称跨卷一致」。

**不改源码**
工具只读源码算哈希，只写 `docs/`。

## 自测记录

| 检查项 | 结果 |
|---|---|
| `inventory` 含 tools | 35 项，tools 5 个文件全部入清单 ✅ |
| `verify` macOS | exit=0，82 passed ✅ |
| `verify` 无 AppKit | exit=0，80 passed / 2 skipped ✅ |
| 写入守卫白名单 | 9/9 场景通过（项目内放行、项目外拒绝、前缀混淆拒绝）✅ |
| 项目内路径放行 | 正常放行，无误拦截 ✅ |

## 插件安装（可选）

`tools/dsh-plugin/` 是 DSH Host 侧插件壳，作用仅是让本工具在插件清单中
可见可管理，不注入任何 Host 服务、不改 UI 行为。

安装方式（与已有本地插件同构）：

```bash
# 1. 链接到项目内插件目录
ln -s "/Volumes/摄影师工具箱128GB/未命名文件夹/FCPX_Studio_Pro/tools/dsh-plugin" \
      "$HOME/.dsh/bundles/fcpx-studio-pro-round"

# 2. 在 ~/.dsh/profiles/desktop/package.json 的 dependencies 加一行
#    "@local/fcpx-studio-pro-round": "link:~/Movies/.dsh/bundles/fcpx-studio-pro-round"

# 3. 在同文件的 dsh.profile.bundles 数组末尾加
#    "@local/fcpx-studio-pro-round"

# 4. 重装依赖并重启 DSH
```

**注意**：第 2、3 步要改的是用户级全局配置 `~/.dsh/profiles/desktop/package.json`，
会影响所有会话。是否安装请你决定；不装也不影响 `tools/round.py` 直接使用。
