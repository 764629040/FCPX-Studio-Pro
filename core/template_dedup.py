"""
R22-A40 模板唯一化（安装前去重 + 安装后唯一性校验 + 历史版本处置）

用户实测痛点：FCPX 里看到「很多个版本」，且「有些版本一触碰就闪退」。
根因是模板扫描树内并存多份同名/同源历史模板目录，且旧版 Media/ 为空 → 打开即崩。

本模块提供：
  - scan_homologous_siblings(target_dir, extra_aliases)
        扫描 parent 下与 target 归一化名相同的兄弟目录（排除 target 自身）
  - dedup_before_install(target_dir, built_moti_sha, expected_media_count,
                         trash_root=None, extra_aliases=None)
        安装前：把所有同源历史兄弟目录移入隐藏回收目录 `.{name}_trash_<ts>`
        （保留=移入回收站而非 rmtree 删除；同文件系统保证 rename 原子）
  - verify_unique_after_install(target_dir, built_moti_sha, expected_media_count,
                                extra_aliases=None)
        安装后：目标内恰 1 个 .moti 且 sha 一致、Media 数符合、parent 无同源兄弟
        任一不满足 → 抛 TemplateUniquenessError，不得返回成功
  - derive_template_aliases(name)
        由模板名推导同源别名（剥离 T 前缀 / 竖横版后缀 / 编号映射），
        用于捕捉 `T01_领衔呈现_竖版` ↔ `01_领衔呈现` ↔ `1_领衔呈现` 这类历史命名。
        注意：**不含裸编号别名**（如 "1" / "23"），理由见下方函数 docstring（A-41）。

core 层不依赖 GUI。
"""
import os
import re
import glob
import hashlib
import time
import xml.etree.ElementTree as ET
from typing import List, Optional, Dict


class TemplateUniquenessError(ValueError):
    """A-40 唯一性校验失败：目标位置存在多版本或 .moti 不一致"""
    pass


# ── 归一化与别名 ────────────────────────────────────────────────────────────

def _template_key(name: str) -> str:
    """归一化模板名：去首尾空格、转小写、压缩内部空白。"""
    return " ".join(str(name).strip().lower().split())


def derive_template_aliases(name: str) -> List[str]:
    """
    由模板名推导同源别名集合（不含自身）。

    规则：
      - 剥离末尾 _竖版 / _横版 / _竖 / _横
      - 剥离开头 T<digits>_ 前缀，得到编号与余名
    例：derive_template_aliases("T01_领衔呈现_竖版")
        → ["01_领衔呈现_竖版"(自身除外), "01_领衔呈现", "领衔呈现", "1_领衔呈现"]

    安全约束（R23 / A-41）：**不包含裸编号别名**（如 "1" / "23"）。
    理由：用户模板库中存在以裸编号命名的独立模板目录
          （如 ~/Movies/.../PSD婚礼字幕/ 下 2..50 共 48 个纯文本独立模板），
          裸编号映射 T01↔1 / T23↔23 缺乏可靠依据，且与用户既有目录直接冲突，
          若参与 dedup 会静默移走用户认为正常的独立模板。
    同源的最终判定改由「名称别名 + 内容级判据」双保险，
    见 dedup_before_install 中的 _confirm_homology（无法确认同源时默认不移动）。
    """
    aliases = set()
    n = name
    for suf in ("_竖版", "_横版", "_竖", "_横"):
        if n.endswith(suf):
            aliases.add(n[:-len(suf)])
            n = n[:-len(suf)]
            break
    m = re.match(r"^T(\d+)_(.*)$", n)
    if m:
        num = m.group(1)
        rest = m.group(2)
        aliases.add(rest)                      # 领衔呈现
        aliases.add(f"{num}_{rest}")           # 01_领衔呈现
        aliases.add(f"{int(num)}_{rest}")      # 1_领衔呈现（带余名，区别于裸编号独立目录）
    aliases.discard(name)
    return list(aliases)


# ── 文件系统探测 ────────────────────────────────────────────────────────────

def _find_moti(dir_path: str) -> Optional[str]:
    motis = sorted(glob.glob(os.path.join(dir_path, "*.moti")))
    return motis[0] if motis else None


def _sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _moti_sha(dir_path: str) -> str:
    m = _find_moti(dir_path)
    return _sha256_of_file(m) if m else ""


def _media_count(dir_path: str) -> int:
    media = os.path.join(dir_path, "Media")
    if not os.path.isdir(media):
        return 0
    return len([n for n in os.listdir(media) if not n.startswith(".")])


def _is_moti_ok(dir_path: str) -> bool:
    m = _find_moti(dir_path)
    if not m:
        return False
    try:
        ET.parse(m)
        return True
    except Exception:
        return False


def _dir_size(path: str) -> int:
    total = 0
    for root, _, names in os.walk(path):
        for nm in names:
            fp = os.path.join(root, nm)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    return total


def _classify_reason(sib_dir: str, built_moti_sha: str,
                     expected_media_count: Optional[int]) -> str:
    """给出该同源兄弟目录被移出的原因（用于报告）。"""
    sib_sha = _moti_sha(sib_dir)
    if built_moti_sha and sib_sha == built_moti_sha:
        return "与本次构建产物 sha256 一致（重复版本，移除以保证唯一性）"
    if not _is_moti_ok(sib_dir):
        return "无有效 .moti（损坏或 Media 为空，触碰闪退嫌疑）"
    if expected_media_count is not None and _media_count(sib_dir) != expected_media_count:
        return f"Media 数 {_media_count(sib_dir)} != 预期 {expected_media_count}（媒体层缺失/错位）"
    return "同名/同源历史版本，多版本并存风险"


# ── 内容级同源判据（R23 / A-41）─────────────────────────────────────────────

def _structure_signature(moti_path: str):
    """
    解析 .moti，抽取结构签名（元素 tag + name/id/description 属性 + reference_base 文本）。

    返回 frozenset[str]，解析失败返回 None。
    同一模板的不同构建版本应共享相同的层名与 reference_base，仅几何/数值不同，
    故签名相等即可判定「结构同源」。
    """
    try:
        tree = ET.parse(moti_path)
        root = tree.getroot()
    except Exception:
        return None
    sig = set()
    for el in root.iter():
        tag = el.tag
        for attr in ("name", "id", "description"):
            v = el.get(attr)
            if v:
                sig.add(f"{tag}.{attr}={v}")
        if tag == "reference_base" and el.text and el.text.strip():
            sig.add(f"refb={el.text.strip()}")
    return frozenset(sig) if sig else None


def _same_template_structure(a: str, b: str) -> bool:
    """两 .moti 是否结构同源（层名 / reference_base 集合一致，容忍少量层更名/增删）。"""
    sa, sb = _structure_signature(a), _structure_signature(b)
    if not sa or not sb:
        return False
    if sa == sb:
        return True
    inter = len(sa & sb)
    return inter >= 0.8 * min(len(sa), len(sb))


def _confirm_homology(sib_dir: str, target_moti_sha: str,
                      target_moti_path: str) -> tuple:
    """
    内容级同源判定（R23 / A-41 核心）。返回 (可移出: bool, 原因: str)。

    判定优先级：
      1. 兄弟目录无有效 .moti → 空壳/损坏，是触碰闪退嫌疑源 → 可移出（隔离）
      2. .moti sha256 与本次构建产物一致 → 重复版本 → 可移出
      3. 结构同源（层名 / reference_base 一致） → 旧版或异构建同模板 → 可移出
      4. 以上均不满足 → 无法确认同源 → **默认不移动**，仅警告交人工/用户复核
    """
    sib_moti = _find_moti(sib_dir)
    if not sib_moti:
        return True, "无有效 .moti（空壳/损坏，触碰闪退嫌疑，隔离移出）"
    if target_moti_sha and _sha256_of_file(sib_moti) == target_moti_sha:
        return True, "sha256 与本次构建产物一致（重复版本，移除以保证唯一性）"
    if target_moti_path and os.path.isfile(target_moti_path) \
            and _same_template_structure(sib_moti, target_moti_path):
        return True, "结构同源（层名 / reference_base 一致，旧版或异构建同模板）"
    return False, "名称匹配别名但内容无法确认同源（默认不移动，仅警告）"


# ── 公开接口 ────────────────────────────────────────────────────────────────

def scan_homologous_siblings(target_dir: str,
                             extra_aliases: Optional[List[str]] = None) -> List[str]:
    """
    扫描 parent 目录下，归一化名与 target 相同（或命中 extra_aliases）的兄弟目录。
    排除 target 自身。返回绝对路径列表。
    """
    target_dir = os.path.abspath(target_dir)
    parent = os.path.dirname(target_dir)
    if not os.path.isdir(parent):
        return []
    key = _template_key(os.path.basename(target_dir))
    aliases = set()
    if extra_aliases:
        aliases = {_template_key(a) for a in extra_aliases}
    siblings = []
    for nm in os.listdir(parent):
        sib = os.path.join(parent, nm)
        if not os.path.isdir(sib):
            continue
        if os.path.abspath(sib) == target_dir:
            continue
        sib_key = _template_key(nm)
        if sib_key == key or (aliases and sib_key in aliases):
            siblings.append(sib)
    return siblings


def dedup_before_install(target_dir: str,
                        built_moti_sha: str,
                        expected_media_count: Optional[int],
                        trash_root: Optional[str] = None,
                        extra_aliases: Optional[List[str]] = None) -> Dict:
    """
    安装前：扫描并处置同源历史兄弟目录。

    行为：仅当内容级判据确认同源（sha 一致 / 结构同源 / 空壳损坏）时，
          才把该同源兄弟目录移入隐藏回收目录（`.{name}_trash_<ts>`）；
          无法确认同源的兄弟目录**默认保留**（仅记入 kept 警告，不移动、不删除）。
    返回处置报告：
        {
          "scanned": int,
          "moved":   [{path, size, sha256, mtime, reason, moved_to}],
          "kept":    [{path, size, sha256, mtime, reason}]   # 无法确认同源，默认不移动
        }
    """
    target_dir = os.path.abspath(target_dir)
    parent = os.path.dirname(target_dir)
    name = os.path.basename(target_dir)
    siblings = scan_homologous_siblings(target_dir, extra_aliases=extra_aliases)
    report: Dict = {"scanned": len(siblings), "moved": [], "kept": []}
    if not siblings:
        return report

    ts = time.strftime("%Y%m%d_%H%M%S")
    if trash_root:
        os.makedirs(trash_root, exist_ok=True)
        trash_base = trash_root
    else:
        # 隐藏前缀，确保 FCPX 扫描树忽略；落在 parent 同文件系统，保证 rename 原子
        trash_base = os.path.join(parent, f".{name}_trash_{ts}")
        os.makedirs(trash_base, exist_ok=True)

    target_moti = _find_moti(target_dir)  # 本次构建产物 .moti（用于内容级同源判定）
    for sib in siblings:
        st = os.stat(sib)
        ok, reason = _confirm_homology(sib, built_moti_sha, target_moti or "")
        entry = {
            "path": sib,
            "size": _dir_size(sib),
            "sha256": _moti_sha(sib) or "N/A",
            "mtime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(st.st_mtime)),
            "reason": reason,
        }
        if not ok:
            # 无法确认同源：默认不移动，仅记录警告，交人工 / 用户复核
            report["kept"].append(entry)
            continue
        dest = os.path.join(trash_base, os.path.basename(sib))
        if os.path.exists(dest):
            dest = f"{dest}_{int(time.time()*1000)}"
        os.rename(sib, dest)
        entry["moved_to"] = dest
        report["moved"].append(entry)
    return report


def verify_unique_after_install(target_dir: str,
                                built_moti_sha: str,
                                expected_media_count: Optional[int],
                                extra_aliases: Optional[List[str]] = None) -> bool:
    """
    安装后校验（A-40 ②）。任一不满足 → 抛 TemplateUniquenessError。
      1. 目标目录内恰有 1 个 .moti，且 sha256 == built_moti_sha
      2. Media 文件数 == expected_media_count（None 则跳过）
      3. parent 下同源兄弟目录应为 0（除 target 自身）
    """
    target_dir = os.path.abspath(target_dir)
    name = os.path.basename(target_dir)

    # 1. 目标内 .moti
    motis = glob.glob(os.path.join(target_dir, "*.moti"))
    if len(motis) != 1:
        raise TemplateUniquenessError(
            f"目标目录 .moti 数量异常: {len(motis)} (应为 1) @ {target_dir}")
    if built_moti_sha and _sha256_of_file(motis[0]) != built_moti_sha:
        raise TemplateUniquenessError(
            f"安装后 .moti sha256 与构建产物不一致 @ {target_dir}")

    # 2. Media 数
    if expected_media_count is not None and _media_count(target_dir) != expected_media_count:
        raise TemplateUniquenessError(
            f"安装后 Media 数 {_media_count(target_dir)} != 预期 {expected_media_count} @ {target_dir}")

    # 3. 同源兄弟：仅「内容确认同源」者才算违反唯一性（R23/A-41 一致性）
    #    名称别名命中但 .moti 内容明显不同的独立模板不视为违规，避免误报。
    #    空壳 / 同 sha / 结构同源 仍会触发——这正是 A-40 要拦截的「真·重复模板」。
    sibs = scan_homologous_siblings(target_dir, extra_aliases=extra_aliases)
    target_moti = _find_moti(target_dir)
    violating = []
    for s in sibs:
        ok, _ = _confirm_homology(s, built_moti_sha, target_moti or "")
        if ok:
            violating.append(s)
    if violating:
        raise TemplateUniquenessError(
            f"安装后仍存在 {len(violating)} 个同源历史版本: {violating}")
    return True
