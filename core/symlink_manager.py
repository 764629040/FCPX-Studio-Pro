"""
外置存储与符号链接管理器（FCPX **用户级** Motion Templates）
============================================================

⚠️ 命名纠错（R31 / A-63）：
本模块历史上的 `system_root` / `DEFAULT_SYSTEM_MOTION_DIR` 指的是
`~/Movies/Motion Templates.localized`，它在 FCPX 语义里是 **「用户」级**，
不是「系统」级，更不是「应用程序包内置」级。原命名会让上层 UI 把用户级
模板误标成「系统内置盘」。本版把内部命名纠正为 `user_tier_root`，
旧名保留为 deprecated 别名（只读转发），避免下游 KeyError / AttributeError。

FCPX 三级归属（供对照，扫描由 Swift 原生壳负责）：
  · 内置  <FCPX>.app/Contents/PlugIns/MediaProviders/MotionEffect.fxp/Contents/Resources/METemplates.localized
  · 用户  ~/Movies/Motion Templates.localized
  · 系统  /Library/Application Support/Final Cut Pro/Templates

本模块只负责「用户级 ⇄ 外置盘」的软链接外置化，不负责跨层级迁移。
"""
import os
import shutil
from typing import Dict, List, Optional, Tuple

# 用户级根目录（历史名字叫 SYSTEM，是误命名；保留别名以防外部引用）
DEFAULT_USER_MOTION_DIR = os.path.expanduser("~/Movies/Motion Templates.localized")
#: @deprecated 误命名，等价于 DEFAULT_USER_MOTION_DIR；请改用新名字
DEFAULT_SYSTEM_MOTION_DIR = DEFAULT_USER_MOTION_DIR

CATEGORIES = [
    "Titles.localized",
    "Effects.localized",
    "Transitions.localized",
    "Generators.localized"
]


class SymlinkManager:
    def __init__(self, external_assets_root: Optional[str] = None):
        #: 用户级 Motion Templates 根目录（不是系统级、不是 App 包内置级）
        self.user_tier_root = DEFAULT_USER_MOTION_DIR
        self.external_root = external_assets_root
        self._ensure_user_tier_dirs()

    @property
    def system_root(self) -> str:
        """@deprecated 误命名：这是用户级根目录。请改用 user_tier_root。"""
        return self.user_tier_root

    @system_root.setter
    def system_root(self, value: str) -> None:
        """@deprecated 保留写入兼容；请改用 user_tier_root。"""
        self.user_tier_root = value

    def set_external_root(self, path: str):
        self.external_root = os.path.abspath(path)
        self._ensure_external_dirs()

    def _ensure_user_tier_dirs(self):
        """确保用户级 Motion Templates 根目录及子目录规范存在"""
        os.makedirs(self.user_tier_root, exist_ok=True)
        for cat in CATEGORIES:
            cat_path = os.path.join(self.user_tier_root, cat)
            os.makedirs(cat_path, exist_ok=True)
            # 建立 .localized 标记文件
            loc_marker = os.path.join(cat_path, ".localized")
            if not os.path.exists(loc_marker):
                try:
                    open(loc_marker, 'a').close()
                except Exception:
                    pass

    def _ensure_system_dirs(self):
        """@deprecated 误命名：实际是用户级目录初始化。请改用 _ensure_user_tier_dirs。"""
        self._ensure_user_tier_dirs()

    def _ensure_external_dirs(self):
        """确保外置存储目录结构规范存在"""
        if not self.external_root:
            return
        os.makedirs(self.external_root, exist_ok=True)
        for cat in CATEGORIES:
            cat_path = os.path.join(self.external_root, cat)
            os.makedirs(cat_path, exist_ok=True)
            loc_marker = os.path.join(cat_path, ".localized")
            if not os.path.exists(loc_marker):
                try:
                    open(loc_marker, 'a').close()
                except Exception:
                    pass

    def link_category_to_system(self, category_name: str, group_name: str) -> Tuple[bool, str]:
        """
        将外置路径下的某个分类包（如 Titles.localized/PSD婚礼字幕）建立软链接至
        **用户级**模板目录（`~/Movies/Motion Templates.localized`）。

        方法名沿用历史命名（`..._to_system`），语义以用户级为准。
        """
        if not self.external_root:
            return False, "未设置外置素材存储根路径"

        real_target = os.path.join(self.external_root, category_name, group_name)
        if not os.path.exists(real_target):
            return False, f"外置真实文件不存在: {real_target}"

        user_link = os.path.join(self.user_tier_root, category_name, group_name)

        if os.path.islink(user_link):
            # 已是软链接，检查指向
            curr_target = os.readlink(user_link)
            if curr_target == real_target:
                return True, "已正确挂载软链接"
            else:
                os.unlink(user_link)

        elif os.path.exists(user_link):
            return False, f"用户级目录已存在同名实体文件夹，无法创建软链接: {user_link}"

        try:
            os.symlink(real_target, user_link)
            return True, f"成功创建外置软链接 -> {user_link}"
        except Exception as e:
            return False, f"创建软链接失败: {str(e)}"

    def unlink_from_system(self, category_name: str, group_name: str) -> Tuple[bool, str]:
        """移除用户级目录上的软链接（停用该插件包，不删除真实文件）"""
        user_link = os.path.join(self.user_tier_root, category_name, group_name)
        if os.path.islink(user_link):
            try:
                os.unlink(user_link)
                return True, "成功停用/移除软链接"
            except Exception as e:
                return False, f"移除软链接失败: {str(e)}"
        elif os.path.exists(user_link):
            return False, "目标不是软链接，为防止误删实体文件，已取消操作"
        return True, "未挂载该链接"

    def migrate_existing_to_external(self, category_name: str, group_name: str) -> Tuple[bool, str]:
        """
        外置化：将用户级现有的实体模板包搬移至外置硬盘，并在原地留存软链接
        """
        if not self.external_root:
            return False, "未设置外置存储根路径"

        user_path = os.path.join(self.user_tier_root, category_name, group_name)
        if not os.path.exists(user_path):
            return False, f"用户级目录不存在该目录: {user_path}"

        if os.path.islink(user_path):
            return True, "该项目已经是外置软链接，无需搬家"

        dest_dir = os.path.join(self.external_root, category_name, group_name)
        if os.path.exists(dest_dir):
            return False, f"外置目标位置已存在同名目录: {dest_dir}"

        try:
            # 移动文件至外置盘
            shutil.move(user_path, dest_dir)
            # 在原地建立软链接指向外置盘
            os.symlink(dest_dir, user_path)
            return True, f"成功将 {group_name} 搬迁至外置盘，并建立软链接"
        except Exception as e:
            return False, f"搬家失败: {str(e)}"

    def get_installed_plugins(self, category_name: str = "Titles.localized") -> List[Dict]:
        """扫描当前**用户级**安装的模板列表及挂载状态"""
        cat_path = os.path.join(self.user_tier_root, category_name)
        results = []
        if not os.path.exists(cat_path):
            return results

        for item in sorted(os.listdir(cat_path)):
            if item.startswith(".") or item == "Icon\r":
                continue
            full_path = os.path.join(cat_path, item)
            is_link = os.path.islink(full_path)
            target = os.readlink(full_path) if is_link else full_path

            # 计算体积
            size_bytes = 0
            try:
                for root, _, files in os.walk(target):
                    for f in files:
                        fp = os.path.join(root, f)
                        if not os.path.islink(fp):
                            size_bytes += os.path.getsize(fp)
            except Exception:
                pass

            results.append({
                "name": item,
                "category": category_name,
                # R31 / A-63：归属层级（本模块只处理用户级）
                "tier": "user",
                "tier_display": "用户",
                "is_symlink": is_link,
                # 磁盘形态与归属层级是两个维度，不允许互相冒充
                "disk_form": "external_link" if is_link else "physical",
                "system_path": full_path,
                "target_path": target,
                "size_mb": round(size_bytes / (1024 * 1024), 2)
            })
        return results
