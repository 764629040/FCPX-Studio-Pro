"""
R21-T3 模板版本管理（列表 / 恢复 / 保留策略）

缺口：build_template_atomic 只产生 `_bak_<ts>`，没有任何消费代码——
      不能列出历史版本、不能一键恢复、也没有保留策略，备份无限堆积。

本模块提供：
  - list_versions(template_dir)   扫描同级 {name}_bak_*，倒序返回 VersionInfo
  - restore_version(...)          恢复前先备份现行版本，再原子换回
  - prune_versions(...)           只保留最近 N 个，其余移入 {name}_trash_*（不直接删）

core 层不依赖 GUI；GUI 接入由调用方完成。
"""
import os
import glob
import shutil
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import List, Optional


@dataclass
class VersionInfo:
    """单个历史版本信息"""
    path: str           # 备份目录绝对路径
    timestamp: float    # 目录 mtime
    size: int           # 目录总字节数
    moti_ok: bool       # .moti 是否存在且 XML 可解析


def _template_name(template_dir: str) -> str:
    return os.path.basename(os.path.abspath(template_dir))


def _dir_size(path: str) -> int:
    total = 0
    for root, _, names in os.walk(path):
        for n in names:
            fp = os.path.join(root, n)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    return total


def _check_moti_ok(backup_path: str) -> bool:
    """检查备份目录内 .moti 是否存在且 XML 可解析"""
    motis = glob.glob(os.path.join(backup_path, "*.moti"))
    if not motis:
        return False
    for m in motis:
        try:
            ET.parse(m)
        except Exception:
            return False
    return True


def list_versions(template_dir: str) -> List[VersionInfo]:
    """
    扫描 template_dir 的同级历史版本备份目录，按时间倒序返回。

    兼容两套命名（R21 非隐藏 + F-4 默认隐藏前缀）：
      - {name}_bak_*      （R21-T3 旧式，用户可见）
      - .{name}_bak_*     （F-4/A-36 默认，隐藏前缀移出 FCPX 扫描树）

    返回列表每项：path / timestamp / size / moti_ok。
    """
    name = _template_name(template_dir)
    parent = os.path.dirname(os.path.abspath(template_dir))
    result = []
    seen = set()
    for pat in (f"{name}_bak_*", f".{name}_bak_*"):
        for bak in glob.glob(os.path.join(parent, pat)):
            if not os.path.isdir(bak):
                continue
            ap = os.path.abspath(bak)
            if ap in seen:
                continue
            seen.add(ap)
            st = os.stat(bak)
            result.append(VersionInfo(
                path=ap,
                timestamp=st.st_mtime,
                size=_dir_size(bak),
                moti_ok=_check_moti_ok(bak),
            ))
    result.sort(key=lambda v: v.timestamp, reverse=True)
    return result


def _dirs_identical(a: str, b: str) -> bool:
    """粗略判断两个目录内容是否完全相同（文件名+大小+mtime）"""
    def snap(path):
        s = {}
        for root, _, names in os.walk(path):
            for n in names:
                fp = os.path.join(root, n)
                try:
                    st = os.stat(fp)
                    s[fp] = (st.st_size, st.st_mtime)
                except OSError:
                    pass
        return s
    return snap(a) == snap(b)


def restore_version(template_dir: str, version_path: str) -> dict:
    """
    把指定备份版本恢复到 template_dir。

    判定树：
      - 若当前目录内容与目标版本完全相同 → 返回 {"restored": False, "reason": "无需恢复"}
      - 否则：先备份当前目录为 {name}_bak_<now>，再把 version_path 原子换回

    返回：{"restored": bool, "backup_path": str|None, "reason": str}
    """
    template_dir = os.path.abspath(template_dir)
    version_path = os.path.abspath(version_path)
    name = _template_name(template_dir)

    if not os.path.isdir(version_path):
        raise FileNotFoundError(f"版本目录不存在: {version_path}")

    # 判定树分支：内容相同则跳过
    if os.path.isdir(template_dir) and _dirs_identical(template_dir, version_path):
        return {"restored": False, "backup_path": None, "reason": "无需恢复（当前与目标版本一致）"}

    # 恢复前必须先备份现行版本（F-4：隐藏前缀，移出 FCPX 扫描树）
    backup_path = None
    if os.path.isdir(template_dir):
        ts = time.strftime("%Y%m%d_%H%M%S")
        bname = _template_name(template_dir)
        bparent = os.path.dirname(os.path.abspath(template_dir))
        backup_path = os.path.join(bparent, f".{bname}_bak_{ts}")
        os.rename(template_dir, backup_path)

    # 原子换回：把 version_path 重命名为正式目录
    # 此时 template_dir 已不存在（要么从未存在，要么已移走备份）
    os.rename(version_path, template_dir)

    return {"restored": True, "backup_path": backup_path, "reason": "已恢复"}


def delete_version(template_dir: str, version_path: str) -> dict:
    """
    删除单个历史版本：将指定备份目录移入回收目录 `.{name}_trash_<ts>`
    （不直接 rmtree，保留可恢复性，与项目“先回收不删除”策略一致）。

    返回：{"deleted": bool, "moved_to": str|None, "reason": str}
    """
    template_dir = os.path.abspath(template_dir)
    version_path = os.path.abspath(version_path)
    if not os.path.isdir(version_path):
        return {"deleted": False, "moved_to": None, "reason": "版本目录不存在"}

    name = _template_name(template_dir)
    parent = os.path.dirname(template_dir)
    ts = time.strftime("%Y%m%d_%H%M%S")
    trash_root = os.path.join(parent, f".{name}_trash_{ts}_{os.getpid()}")
    os.makedirs(trash_root, exist_ok=True)
    dest = os.path.join(trash_root, os.path.basename(version_path))
    os.rename(version_path, dest)
    return {"deleted": True, "moved_to": dest, "reason": "已移入回收目录"}


def prune_versions(template_dir: str, keep: int = 5) -> List[str]:
    """
    只保留最近 keep 个版本，其余移入回收目录 `{name}_trash_<ts>`（不直接 rmtree）。

    返回被移入回收目录的路径列表。
    """
    if keep < 0:
        raise ValueError(f"keep 不能为负: {keep}")

    versions = list_versions(template_dir)
    if len(versions) <= keep:
        return []

    name = _template_name(template_dir)
    parent = os.path.dirname(os.path.abspath(template_dir))
    trash_root = os.path.join(parent, f".{name}_trash_{time.strftime('%Y%m%d_%H%M%S')}")
    os.makedirs(trash_root, exist_ok=True)

    # 保留前 keep 个（已倒序），其余移入回收目录
    removed = []
    for v in versions[keep:]:
        dest = os.path.join(trash_root, os.path.basename(v.path))
        os.rename(v.path, dest)
        removed.append(dest)

    return removed
