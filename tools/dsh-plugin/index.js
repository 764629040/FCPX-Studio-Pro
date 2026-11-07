/**
 * FCPX Studio Pro 审核轮次自动化 —— DSH Host 侧插件。
 *
 * 本插件不注入任何 Host 服务，也不改动 UI 行为；它的作用是：
 *   1. 让项目内的轮次自动化工具在插件清单里有一个可见、可管理的条目；
 *   2. 通过脚本暴露统一入口，避免每轮重复手写指纹与测试命令。
 *
 * 实际执行逻辑在项目根目录的 tools/round.py：
 *   python3 tools/round.py all --tag roundN
 *
 * 设计约束（与项目红线一致）：
 *   - 退出码直接取 subprocess.returncode，绝不经 tee / 管道
 *   - 写入前硬拦截 /Volumes/NO NAME/128（只读铁律）
 *   - 不声称跨卷一致，清单只记 canonical_path
 */
export const name = '@local/fcpx-studio-pro-round';

export const ROUND_TOOL = 'tools/round.py';

export const COMMANDS = {
  inventory: 'python3 tools/round.py inventory --tag roundN',
  verify: 'python3 tools/round.py verify --tag roundN',
  all: 'python3 tools/round.py all --tag roundN',
};

/**
 * Host half：本 bundle 不提供服务，row 仅用于在插件清单中可见。
 */
export function apply() {}
