"""
PyQt6 FCPX 全能素材库与外置管理中心组件
支持外置存储路径设置、已安装插件扫描、一键启用/停用、系统盘搬家与拖拽安装。
"""
import os
import time
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QTableWidget, 
    QTableWidgetItem, QHeaderView, QPushButton, QFileDialog, 
    QMessageBox, QComboBox, QLineEdit, QDialog, QMenu, 
    QListWidget, QListWidgetItem
)
from PyQt6.QtCore import Qt, pyqtSignal
from core.symlink_manager import SymlinkManager
from core.template_versions import (
    list_versions, restore_version, prune_versions, delete_version,
)

class AssetHubPanel(QWidget):
    open_template_in_designer = pyqtSignal(str) # 传递模板路径回炉编辑

    def __init__(self, symlink_manager: SymlinkManager, parent=None):
        super().__init__(parent)
        self.mgr = symlink_manager
        self.current_category = "Titles.localized"
        self._init_ui()
        self.refresh_plugins()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(15, 15, 15, 15)
        layout.setSpacing(12)

        # 1. 顶部存储路径与系统盘节省指示条
        storage_bar = QHBoxLayout()
        storage_bar.setSpacing(10)

        path_label = QLabel("🟢 外置存储路径:")
        path_label.setStyleSheet("font-weight: bold; color: #34C759; font-size: 12px;")
        storage_bar.addWidget(path_label)

        self.path_display = QLineEdit(self.mgr.external_root or "未设置外置路径（使用系统盘）")
        self.path_display.setReadOnly(True)
        self.path_display.setStyleSheet("background-color: #1A1C22; color: #E0E2E8; border: 1px solid #2B2D35; border-radius: 6px; padding: 5px;")
        storage_bar.addWidget(self.path_display, stretch=1)

        self.change_path_btn = QPushButton("📁 更换外置路径")
        self.change_path_btn.setStyleSheet("background-color: #252832; color: #FFF; padding: 6px 12px; border-radius: 6px;")
        self.change_path_btn.clicked.connect(self._on_change_path)
        storage_bar.addWidget(self.change_path_btn)

        self.migrate_btn = QPushButton("⚡️ 外置化所选 (0占用)")
        self.migrate_btn.setStyleSheet("background-color: #34C759; color: #FFF; font-weight: bold; padding: 6px 12px; border-radius: 6px;")
        self.migrate_btn.clicked.connect(self._on_migrate_all)
        storage_bar.addWidget(self.migrate_btn)

        layout.addLayout(storage_bar)

        # 2. 分类筛选与搜索条
        filter_bar = QHBoxLayout()
        filter_bar.addWidget(QLabel("分类类别:"))
        self.cat_combo = QComboBox()
        self.cat_combo.addItems([
            "Titles.localized (标题与字幕)",
            "Effects.localized (视频特效)",
            "Transitions.localized (转场过渡)",
            "Generators.localized (背景发生器)"
        ])
        self.cat_combo.currentIndexChanged.connect(self._on_cat_changed)
        self.cat_combo.setStyleSheet("background-color: #1A1C22; color: #FFF; padding: 4px; border: 1px solid #2B2D35;")
        filter_bar.addWidget(self.cat_combo)

        filter_bar.addStretch()

        self.refresh_btn = QPushButton("🔄 刷新列表")
        self.refresh_btn.clicked.connect(self.refresh_plugins)
        filter_bar.addWidget(self.refresh_btn)

        layout.addLayout(filter_bar)

        # 3. 插件资产表格
        self.table = QTableWidget()
        self.table.setColumnCount(5)
        self.table.setHorizontalHeaderLabels(["插件名称", "体积 (MB)", "存储位置", "运行状态", "快捷操作"])
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(4, QHeaderView.ResizeMode.ResizeToContents)
        self.table.setStyleSheet("""
            QTableWidget {
                background-color: #16171B;
                border: 1px solid #2B2D35;
                border-radius: 8px;
                color: #FFFFFF;
                font-size: 12px;
            }
            QHeaderView::section {
                background-color: #1F2128;
                color: #A0A4B0;
                border: none;
                padding: 6px;
                font-size: 11px;
            }
        """)
        layout.addWidget(self.table, stretch=1)

        # F-1 (R22-T3)：右键模板行弹出历史版本管理
        self.table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self._on_table_context_menu)
        self._current_plugins = []

    def _on_table_context_menu(self, pos):
        row = self.table.indexAt(pos).row()
        if row < 0 or row >= len(self._current_plugins):
            return
        plugin = self._current_plugins[row]
        menu = QMenu(self)
        act_versions = menu.addAction("🕑 历史版本...")
        action = menu.exec(self.table.viewport().mapToGlobal(pos))
        if action == act_versions:
            dlg = VersionManagerDialog(plugin["target_path"], plugin["name"], self)
            dlg.exec()
            self.refresh_plugins()

    def _on_change_path(self):
        new_dir = QFileDialog.getExistingDirectory(self, "选择外置素材库存储目录")
        if new_dir:
            self.mgr.set_external_root(new_dir)
            self.path_display.setText(new_dir)
            self.refresh_plugins()

    def _on_cat_changed(self, idx):
        cats = ["Titles.localized", "Effects.localized", "Transitions.localized", "Generators.localized"]
        self.current_category = cats[idx]
        self.refresh_plugins()

    def refresh_plugins(self):
        plugins = self.mgr.get_installed_plugins(self.current_category)
        self._current_plugins = plugins
        self.table.setRowCount(len(plugins))

        for row, p in enumerate(plugins):
            # 名称
            self.table.setItem(row, 0, QTableWidgetItem(p["name"]))
            # 体积
            self.table.setItem(row, 1, QTableWidgetItem(f"{p['size_mb']} MB"))
            # 存储位置：两个维度必须都在（R31 / A-63）
            #   归属层级固定为「用户」（本页只扫描用户级），磁盘形态单独说明
            loc_str = "🟢 用户级 · 软链接(0占用)" if p["is_symlink"] else "📁 用户级 · 实体(占用存储)"
            loc_item = QTableWidgetItem(loc_str)
            if p["is_symlink"]:
                loc_item.setForeground(Qt.GlobalColor.green)
            else:
                loc_item.setForeground(Qt.GlobalColor.yellow)
            self.table.setItem(row, 2, loc_item)

            # 运行状态
            status_item = QTableWidgetItem("已在 FCPX 启用")
            self.table.setItem(row, 3, status_item)

            # 操作按钮栏
            action_btn = QPushButton("🎨 回炉设计器")
            action_btn.setStyleSheet("background-color: #0A84FF; color: white; padding: 3px 8px; font-size: 11px; border-radius: 4px;")
            target_path = p["target_path"]
            action_btn.clicked.connect(lambda _, path=target_path: self.open_template_in_designer.emit(path))
            self.table.setCellWidget(row, 4, action_btn)

    def _on_migrate_all(self):
        if not self.mgr.external_root:
            QMessageBox.warning(self, "提示", "请先选择外置存储路径！")
            return
        
        plugins = self.mgr.get_installed_plugins(self.current_category)
        non_symlinks = [p for p in plugins if not p["is_symlink"]]

        if not non_symlinks:
            QMessageBox.information(self, "提示", "当前分类下所有插件已全部外置化，系统盘占用为 0！")
            return

        reply = QMessageBox.question(
            self, "确认外置化", 
            f"检测到 {len(non_symlinks)} 项用户级实体模板，是否立即搬移至外置盘并建立软链接？",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        )
        if reply == QMessageBox.StandardButton.Yes:
            count = 0
            for p in non_symlinks:
                ok, msg = self.mgr.migrate_existing_to_external(self.current_category, p["name"])
                if ok:
                    count += 1
            QMessageBox.information(self, "完成", f"已成功将 {count} 项模板搬移至外置盘，并建立软链接！系统盘空间已释放。")
            self.refresh_plugins()


class VersionManagerDialog(QDialog):
    """F-1 (R22-T3) 单个模板的历史版本管理：列表 / 恢复 / 删除 / 清理"""

    def __init__(self, template_dir: str, name: str, parent=None):
        super().__init__(parent)
        self.template_dir = os.path.abspath(template_dir)
        self.name = name
        self.versions = []
        self.setWindowTitle(f"历史版本管理 — {name}")
        self.resize(580, 440)
        self._init_ui()
        self._load_versions()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 12, 12, 12)
        layout.setSpacing(10)

        info = QLabel(f"模板目录: {self.template_dir}")
        info.setStyleSheet("color:#8E8E93;font-size:11px;")
        layout.addWidget(info)

        self.list_widget = QListWidget()
        self.list_widget.currentRowChanged.connect(self._on_selected)
        layout.addWidget(self.list_widget, stretch=1)

        btn_layout = QHBoxLayout()
        self.restore_btn = QPushButton("♻️ 恢复此版本")
        self.restore_btn.clicked.connect(self._on_restore)
        self.delete_btn = QPushButton("🗑 移入回收站")
        self.delete_btn.clicked.connect(self._on_delete)
        btn_layout.addWidget(self.restore_btn)
        btn_layout.addWidget(self.delete_btn)
        btn_layout.addStretch()
        self.prune_btn = QPushButton("🧹 仅保留最近 5 个")
        self.prune_btn.clicked.connect(self._on_prune)
        btn_layout.addWidget(self.prune_btn)
        layout.addLayout(btn_layout)

        self.status_lbl = QLabel("")
        self.status_lbl.setStyleSheet("color:#A0A4B0;font-size:11px;")
        layout.addWidget(self.status_lbl)

    def _load_versions(self):
        self.list_widget.clear()
        self.versions = list_versions(self.template_dir)
        if not self.versions:
            QListWidgetItem("（无历史版本备份）", self.list_widget)
            self.restore_btn.setEnabled(False)
            self.delete_btn.setEnabled(False)
            self.prune_btn.setEnabled(False)
            return
        for v in self.versions:
            t = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(v.timestamp))
            flag = "✅ 可恢复" if v.moti_ok else "⚠️ 损坏"
            item = QListWidgetItem(f"{t}  |  {v.size/1024:.1f} KB  |  {flag}")
            item.setData(Qt.ItemDataRole.UserRole, v.path)
            self.list_widget.addItem(item)
        self.restore_btn.setEnabled(False)
        self.delete_btn.setEnabled(False)

    def _on_selected(self, row):
        has = 0 <= row < len(self.versions)
        self.restore_btn.setEnabled(has)
        self.delete_btn.setEnabled(has)

    def _on_restore(self):
        row = self.list_widget.currentRow()
        if not (0 <= row < len(self.versions)):
            return
        vp = self.versions[row].path
        ret = QMessageBox.question(
            self, "确认恢复",
            f"将把以下历史版本恢复为当前活动模板:\n{vp}\n\n"
            "当前活动版本会先自动备份。确认？",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if ret != QMessageBox.StandardButton.Yes:
            return
        try:
            res = restore_version(self.template_dir, vp)
            self.status_lbl.setText(res["reason"])
            if res["restored"]:
                self._load_versions()
        except Exception as e:
            QMessageBox.critical(self, "恢复失败", str(e))

    def _on_delete(self):
        row = self.list_widget.currentRow()
        if not (0 <= row < len(self.versions)):
            return
        vp = self.versions[row].path
        ret = QMessageBox.question(
            self, "确认删除",
            f"将把该历史版本移入回收站（不直接删除）:\n{vp}\n\n确认？",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if ret != QMessageBox.StandardButton.Yes:
            return
        try:
            res = delete_version(self.template_dir, vp)
            self.status_lbl.setText(res["reason"])
            if res["deleted"]:
                self._load_versions()
        except Exception as e:
            QMessageBox.critical(self, "删除失败", str(e))

    def _on_prune(self):
        try:
            removed = prune_versions(self.template_dir, keep=5)
            self.status_lbl.setText(f"已清理 {len(removed)} 个旧版本至回收目录")
            self._load_versions()
        except Exception as e:
            QMessageBox.critical(self, "清理失败", str(e))
