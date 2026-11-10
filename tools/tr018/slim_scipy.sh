#!/bin/zsh
# TR-018: scipy 只保留 ndimage / interpolate / _lib，其余子包删除。
# 用法: slim_scipy.sh <scipy目录绝对路径>
# 规则与 /tmp 实验、R2.app 落地完全一致，禁止手工另写一套。
set -eu
SCIPY="$1"
[ -d "$SCIPY/ndimage" ] || { echo "FATAL: 不是 scipy 目录: $SCIPY" >&2; exit 2; }
[ -f "$SCIPY/__init__.py" ] || { echo "FATAL: 缺 __init__.py: $SCIPY" >&2; exit 2; }
KEEP="ndimage interpolate _lib .dylibs"
removed=()
for d in "$SCIPY"/*(/N); do
  b=${d:t}
  case " $KEEP " in
    *" $b "*) ;;
    *) removed+=("$b"); rm -rf "$d" ;;
  esac
done
echo "REMOVED(${removed}): ${(j:, :)removed}"
echo "KEPT_DIRS: $(cd "$SCIPY" && find . -maxdepth 1 -type d ! -name . -exec basename {} \; | sort | tr '\n' ' ')"
