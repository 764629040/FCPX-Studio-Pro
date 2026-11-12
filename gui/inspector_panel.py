"""
PyQt6 属性与发布控制面板组件 (树状层级与缩略图增强版)
管理图层树结构（支持折叠/展开、真实缩略图图标、类型徽章、可见性开关、发布至 FCPX 开关）及当前选中图层的 Motion 参数微调。
"""
from typing import List, Optional, Dict, Any
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QTreeWidget, 
    QTreeWidgetItem, QHeaderView, QCheckBox, QPlainTextEdit, 
    QDoubleSpinBox, QLineEdit, QGroupBox, QPushButton, QMenu
)
from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtGui import QIcon, QPixmap, QColor, QBrush, QCursor


class InspectorPanel(QWidget):
    layer_modified_signal = pyqtSignal(object)
    layer_selected_signal = pyqtSignal(object)
    badge_clicked_signal = pyqtSignal(object)
    save_template_signal = pyqtSignal()
    batch_export_signal = pyqtSignal()
    # 手动纠错：多选合并（传 1-based 层索引列表）/ 单层按连通块拆分（传层索引）
    layers_merge_requested = pyqtSignal(list)
    layer_split_requested = pyqtSignal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.current_layer_info = None
        self.layers = []
        self._init_ui()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 10)
        layout.setSpacing(10)

        # 1. 顶部标题
        title = QLabel("图层层级树与 FCPX 发布控制")
        title.setStyleSheet("font-weight: bold; font-size: 13px; color: #E0E2E8;")
        layout.addWidget(title)

        # 2. 树状层级展示控件
        self.tree = QTreeWidget()
        self.tree.setColumnCount(5)
        self.tree.setHeaderLabels(["图层名称", "显示", "发布", "锁定", "字体/预览"])
        self.tree.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.tree.header().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.tree.header().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self.tree.header().setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        # 第 4 列是说明文字，按内容自适应会把图层名挤到看不见；
        # 固定起始宽度 + 关掉「最后一列占满剩余」的表头默认行为，图层名才有地方显示。
        self.tree.header().setStretchLastSection(False)
        self.tree.header().setSectionResizeMode(4, QHeaderView.ResizeMode.Interactive)
        self.tree.setColumnWidth(4, 84)
        self.tree.setSelectionMode(QTreeWidget.SelectionMode.ExtendedSelection)
        self.tree.setAnimated(True)
        self.tree.setStyleSheet("""
            QTreeWidget {
                background-color: #16171B;
                border: 1px solid #2B2D35;
                border-radius: 8px;
                color: #FFFFFF;
                font-size: 12px;
            }
            QTreeWidget::item {
                padding: 4px;
                border-bottom: 1px solid #1E2026;
            }
            QTreeWidget::item:selected {
                background-color: #242732;
                border-left: 3px solid #0A84FF;
            }
            QHeaderView::section {
                background-color: #1F2128;
                color: #A0A4B0;
                border: none;
                padding: 4px;
                font-size: 11px;
            }
        """)
        self.tree.itemSelectionChanged.connect(self._on_tree_selection_changed)
        self.tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self._on_tree_context_menu)
        layout.addWidget(self.tree, stretch=1)

        # 兼容旧代码引用
        self.table = self.tree

        # 3. 选中图层参数微调 Group
        self.detail_group = QGroupBox("选中图层 Motion 属性")
        self.detail_group.setStyleSheet("""
            QGroupBox {
                border: 1px solid #2B2D35;
                border-radius: 8px;
                margin-top: 10px;
                font-weight: bold;
                color: #0A84FF;
                padding: 10px;
            }
            QGroupBox::title {
                subcontrol-origin: margin;
                left: 10px;
                padding: 0 5px;
            }
        """)
        form_layout = QVBoxLayout(self.detail_group)
        form_layout.setSpacing(8)

        # 字体状态与缺字标记徽章按钮 (点击可跳转诊断报告)
        self.font_badge_btn = QPushButton("🟢 字体完全支持 (100%)")
        self.font_badge_btn.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        self.font_badge_btn.setStyleSheet("""
            QPushButton {
                background-color: #14301C;
                color: #30D158;
                border: 1px solid #30D158;
                border-radius: 4px;
                padding: 4px 8px;
                font-size: 11px;
                font-weight: bold;
                text-align: left;
            }
            QPushButton:hover {
                background-color: #1B4526;
            }
        """)
        self.font_badge_btn.clicked.connect(self._on_font_badge_clicked)
        form_layout.addWidget(self.font_badge_btn)

        # 文字多行编辑
        form_layout.addWidget(QLabel("文字内容 (支持竖排换行):"))
        self.text_edit = QPlainTextEdit()
        self.text_edit.setFixedHeight(65)
        self.text_edit.setStyleSheet("background-color: #1A1C22; color: #FFF; border: 1px solid #333; border-radius: 4px;")
        self.text_edit.textChanged.connect(self._on_text_edited)
        form_layout.addWidget(self.text_edit)

        # 坐标 X / Y
        pos_layout = QHBoxLayout()
        self.spin_x = QDoubleSpinBox()
        self.spin_x.setRange(-2000, 2000)
        self.spin_x.setPrefix("X: ")
        self.spin_x.valueChanged.connect(self._on_pos_edited)

        self.spin_y = QDoubleSpinBox()
        self.spin_y.setRange(-2000, 2000)
        self.spin_y.setPrefix("Y: ")
        self.spin_y.valueChanged.connect(self._on_pos_edited)

        pos_layout.addWidget(self.spin_x)
        pos_layout.addWidget(self.spin_y)
        form_layout.addLayout(pos_layout)

        # 字体与字号
        font_layout = QHBoxLayout()
        self.font_line = QLineEdit()
        self.font_line.setPlaceholderText("字体 PostScript 名")
        self.font_line.textChanged.connect(self._on_font_edited)

        self.size_spin = QDoubleSpinBox()
        self.size_spin.setRange(5, 500)
        self.size_spin.setPrefix("字号: ")
        self.size_spin.valueChanged.connect(self._on_size_edited)

        font_layout.addWidget(self.font_line, stretch=2)
        font_layout.addWidget(self.size_spin, stretch=1)
        form_layout.addLayout(font_layout)

        layout.addWidget(self.detail_group)

        # 4. 底部快捷操作
        btn_layout = QHBoxLayout()
        self.save_btn = QPushButton("💾 保存当前模板 (.moti)")
        self.save_btn.setStyleSheet("background-color: #252832; color: #FFF; padding: 8px; border-radius: 6px;")
        self.save_btn.clicked.connect(self.save_template_signal.emit)

        self.export_all_btn = QPushButton("🚀 一键批量导出至 FCPX")
        self.export_all_btn.setStyleSheet("background-color: #0A84FF; color: #FFF; font-weight: bold; padding: 8px; border-radius: 6px;")
        self.export_all_btn.clicked.connect(self.batch_export_signal.emit)

        btn_layout.addWidget(self.save_btn)
        btn_layout.addWidget(self.export_all_btn)
        layout.addLayout(btn_layout)

    # ── R26-A47②：缺字层诊断高亮 ────────────────────────────────────────────
    # C-10 要求"诊断面板高亮缺字/缺字体风险层"。数据来源为 psd_parser 的一等字段：
    #   missing_glyph_visible_marker / marked_text / highlight_missing_font /
    #   font_info.has_missing_glyphs / font_info.missing_chars
    # 呈现方式：⚠ 徽标 + 橙红前景色 + tooltip 明细 + 预览列直接展示 marked_text
    #（tofu □ 可见，用户肉眼可辨缺字位置）。
    _MISSING_GLYPH_COLOR = QColor("#E67E22")  # 橙：字体风险高亮色

    @staticmethod
    def _missing_glyph_state(info) -> Dict[str, Any]:
        """判定图层是否需要缺字高亮（纯逻辑委托 core.missing_font，可 headless 单测）。"""
        from core.missing_font import missing_glyph_layer_state
        return missing_glyph_layer_state(info)

    def _apply_missing_glyph_highlight(self, item: QTreeWidgetItem, info) -> None:
        """对缺字/缺字体风险层应用可见高亮（树模式与扁平模式共用）。"""
        state = self._missing_glyph_state(info)
        if not state["highlight"]:
            return
        # 1. ⚠ 徽标 + 橙色前景（名称列）
        name = item.text(0)
        if "⚠" not in name:
            item.setText(0, f"⚠ {name}")
        item.setForeground(0, QBrush(self._MISSING_GLYPH_COLOR))
        # 2. 预览列前景同步
        item.setForeground(3, QBrush(self._MISSING_GLYPH_COLOR))
        # 3. tooltip 明细：缺哪些字 + 风险类型 + 标记版预览
        missing = state["missing_chars"]
        missing_disp = "".join(missing[:20]) if missing else "未知"
        marked_disp = state["marked_text"].replace("\n", " ").strip()[:28]
        item.setToolTip(0, (
            f"缺字风险层（{state['reason']}）\n"
            f"缺失字符: {missing_disp}\n"
            f"模板内将显示方框标记（□）: {marked_disp}"
        ))
        # 4. 预览列直接展示 marked_text（□ 肉眼可见，非仅 tooltip）
        if getattr(info, "kind", "") == "type" and state["marked_text"]:
            font_label = (getattr(info, "font_name", "") or "").split("-")[0]
            preview = state["marked_text"].replace("\n", " ").strip()[:14]
            item.setText(3, f'"⚠{preview}" ({font_label})')

    def load_layers(self, layers, layer_tree: Optional[List[Dict[str, Any]]] = None):
        """
        载入图层列表与层级树。
        支持层级折叠展开、缩略图图标、类型徽章与状态绑定。
        """
        self.layers = layers
        self.tree.clear()

        # 图层类型徽章映射
        type_badges = {
            "type": "[文本]",
            "smartobject": "[智能对象]",
            "shape": "[形状]",
            "pixel": "[像素]",
            "group": "[组]",
            "adjustment": "[调整层]",
            "fallback_png": "[位图]"
        }

        # 建立图层信息速查表 (通过 name 或 layer_path)
        layer_map = {getattr(info, "layer_path", info.name): info for info in layers}
        name_map = {info.name: info for info in layers}

        def _create_tree_item(node: Dict[str, Any], parent_item: Optional[QTreeWidgetItem] = None) -> QTreeWidgetItem:
            item = QTreeWidgetItem(parent_item) if parent_item else QTreeWidgetItem(self.tree)
            name = node.get("name", "Unnamed")
            l_type = node.get("layer_type", "type")
            badge = type_badges.get(l_type, f"[{l_type}]")
            
            # 列 0: 图标与名称
            item.setText(0, f"{badge} {name}")
            thumb_bytes = node.get("thumbnail_bytes")
            if thumb_bytes:
                pix = QPixmap()
                if pix.loadFromData(thumb_bytes):
                    item.setIcon(0, QIcon(pix))
            elif node.get("is_group"):
                # 图层组专用文件夹标识
                item.setText(0, f"📁 {badge} {name}")

            # 匹配对应的 Motion LayerInfo
            l_path = node.get("layer_path", name)
            info = layer_map.get(l_path) or name_map.get(name)

            if info is not None:
                item.setData(0, Qt.ItemDataRole.UserRole, info)

                # 列 1: 眼睛可见性 Checkbox
                vis_cb = QCheckBox()
                vis_cb.setChecked(info.visible)
                vis_cb.stateChanged.connect(lambda state, target_info=info: self._on_vis_toggled(target_info, state))
                self.tree.setItemWidget(item, 1, vis_cb)

                # 列 2: 发布 Checkbox
                pub_cb = QCheckBox()
                pub_cb.setChecked(info.is_published)
                pub_cb.stateChanged.connect(lambda state, target_info=info: self._on_pub_toggled(target_info, state))
                self.tree.setItemWidget(item, 2, pub_cb)

                # 列 3: 锁定 Checkbox (D-3)
                lock_cb = QCheckBox()
                lock_cb.setChecked(bool(getattr(info, "locked", False)))
                lock_cb.stateChanged.connect(lambda state, target_info=info: self._on_lock_toggled(target_info, state))
                self.tree.setItemWidget(item, 3, lock_cb)

                # 列 4: 预览与字体信息
                if info.kind == "type":
                    preview = info.text.replace("\n", " ").strip()[:14]
                    font_label = info.font_name.split("-")[0]
                    item.setText(4, f'"{preview}" ({font_label})')
                else:
                    item.setText(4, f"[{info.disposition_reason[:8]}]")
                    item.setToolTip(4, info.disposition_reason)
                # R26-A47②：缺字层可见高亮（⚠徽标/橙前景/tooltip/marked_text 预览）
                self._apply_missing_glyph_highlight(item, info)
            else:
                # 组节点或已过滤节点
                item.setText(3, f"[{node.get('reason', '容器/已忽略')[:12]}]")

            # 递归处理子节点
            for child in node.get("children", []):
                _create_tree_item(child, parent_item=item)

            item.setExpanded(True)
            return item

        if layer_tree:
            for root_node in layer_tree:
                _create_tree_item(root_node)
        else:
            # 平铺后备模式
            for info in layers:
                item = QTreeWidgetItem(self.tree)
                badge = type_badges.get(info.kind, f"[{info.kind}]")
                item.setText(0, f"{badge} {info.name}")
                if info.thumbnail_bytes:
                    pix = QPixmap()
                    if pix.loadFromData(info.thumbnail_bytes):
                        item.setIcon(0, QIcon(pix))

                item.setData(0, Qt.ItemDataRole.UserRole, info)

                vis_cb = QCheckBox()
                vis_cb.setChecked(info.visible)
                vis_cb.stateChanged.connect(lambda state, target_info=info: self._on_vis_toggled(target_info, state))
                self.tree.setItemWidget(item, 1, vis_cb)

                pub_cb = QCheckBox()
                pub_cb.setChecked(info.is_published)
                pub_cb.stateChanged.connect(lambda state, target_info=info: self._on_pub_toggled(target_info, state))
                self.tree.setItemWidget(item, 2, pub_cb)

                # 列 3: 锁定 Checkbox (D-3)
                lock_cb = QCheckBox()
                lock_cb.setChecked(bool(getattr(info, "locked", False)))
                lock_cb.stateChanged.connect(lambda state, target_info=info: self._on_lock_toggled(target_info, state))
                self.tree.setItemWidget(item, 3, lock_cb)

                if info.kind == "type":
                    preview = info.text.replace("\n", " ").strip()[:14]
                    font_label = info.font_name.split("-")[0]
                    item.setText(4, f'"{preview}" ({font_label})')
                else:
                    item.setText(4, f"[{info.disposition_reason[:8]}]")
                    item.setToolTip(4, info.disposition_reason)
                # R26-A47②：缺字层可见高亮（扁平后备模式同样生效）
                self._apply_missing_glyph_highlight(item, info)

        # 默认选中首个项目
        if self.tree.topLevelItemCount() > 0:
            first_item = self.tree.topLevelItem(0)
            self.tree.setCurrentItem(first_item)

    def _on_vis_toggled(self, info, state):
        info.visible = (state == Qt.CheckState.Checked.value or state == 2)
        # D-3：可见性持久化到 .moti 的 enabled 属性 + Motion 原生 flags 位
        path = getattr(self, "_moti_path", None)
        if path:
            try:
                from core.moti_layer_io import set_layer_enabled
                set_layer_enabled(path, getattr(info, "index", None) or info.name, info.visible)
            except Exception as exc:
                print(f"[warn] moti visibility writeback failed: {exc}")
        self.layer_modified_signal.emit(info)

    def _on_lock_toggled(self, info, state):
        # D-3：锁定状态持久化到 .moti 的 locked 属性；锁定后画布禁止拖拽
        info.locked = (state == Qt.CheckState.Checked.value or state == 2)
        path = getattr(self, "_moti_path", None)
        if path:
            try:
                from core.moti_layer_io import set_layer_locked
                set_layer_locked(path, getattr(info, "index", None) or info.name, info.locked)
            except Exception as exc:
                print(f"[warn] moti lock writeback failed: {exc}")
        self.layer_modified_signal.emit(info)

    def set_moti_path(self, path: str) -> None:
        """设置当前编辑的 .moti 路径，眼睛/锁定开关将写回到此文件。"""
        self._moti_path = path

    def _on_pub_toggled(self, info, state):
        info.is_published = (state == Qt.CheckState.Checked.value or state == 2)

    def _on_tree_context_menu(self, pos):
        """层树右键：多选合并 / 单层按连通块拆分（手动纠错入口）。"""
        items = self.tree.selectedItems()
        infos = [it.data(0, Qt.ItemDataRole.UserRole) for it in items]
        infos = [i for i in infos if i is not None]
        if not infos:
            return

        menu = QMenu(self)
        if len(infos) >= 2:
            act = menu.addAction("合并所选 %d 层" % len(infos))
            act.triggered.connect(
                lambda _=False, idx=[i.index for i in infos]: self.layers_merge_requested.emit(idx))
        else:
            act = menu.addAction("按连通块拆分这层")
            act.triggered.connect(
                lambda _=False, idx=infos[0].index: self.layer_split_requested.emit(idx))
        menu.addSeparator()
        menu.addAction("改动只在本次导出生效，不动源分层文件").setEnabled(False)
        menu.exec(self.tree.viewport().mapToGlobal(pos))

    def _on_tree_selection_changed(self):
        items = self.tree.selectedItems()
        if not items:
            return
        # 多选时参数面板跟随最后点中的那一层，而不是列表里排最前的
        cur = self.tree.currentItem()
        item = cur if cur in items else items[0]
        info = item.data(0, Qt.ItemDataRole.UserRole)
        if info is not None:
            self.current_layer_info = info
            self.text_edit.blockSignals(True)
            self.spin_x.blockSignals(True)
            self.spin_y.blockSignals(True)
            self.font_line.blockSignals(True)
            self.size_spin.blockSignals(True)

            self.text_edit.setPlainText(info.text)
            self.spin_x.setValue(info.motion_pos[0])
            self.spin_y.setValue(info.motion_pos[1])
            self.font_line.setText(info.font_name)
            self.size_spin.setValue(info.font_size)

            self.text_edit.blockSignals(False)
            self.spin_x.blockSignals(False)
            self.spin_y.blockSignals(False)
            self.font_line.blockSignals(False)
            self.size_spin.blockSignals(False)

            # 刷新字体徽章按钮展示
            if info.kind == "type":
                f_info = getattr(info, "font_info", {}) or {}
                det = f_info.get("detection_status", "detected")
                missing = f_info.get("missing_chars", [])
                has_risk = f_info.get("has_missing_glyphs", False)
                cov = f_info.get("glyph_coverage")

                if det == "font_missing":
                    b_txt = f"🔴 原始字体未安装 (回退: {f_info.get('fallback_font', 'PingFang')}) ➜ 查看诊断"
                    bg, fg = "#3D1418", "#FF453A"
                elif has_risk and missing:
                    miss_s = ", ".join(missing[:3]) + ("..." if len(missing) > 3 else "")
                    b_txt = f"🟠 缺少字形: {miss_s} ➜ 查看诊断"
                    bg, fg = "#3D2914", "#FF9F0A"
                elif cov is None:
                    b_txt = "🟡 无法验证字形 ➜ 查看诊断"
                    bg, fg = "#3D3514", "#FFD60A"
                else:
                    b_txt = "🟢 字体 100% 完全支持 ➜ 查看诊断"
                    bg, fg = "#14301C", "#30D158"
            else:
                b_txt = f"🟠 [{info.disposition.upper()}] {info.disposition_reason[:18]} ➜ 查看诊断"
                bg, fg = "#3D2914", "#FF9F0A"

            self.font_badge_btn.setText(b_txt)
            self.font_badge_btn.setStyleSheet(f"""
                QPushButton {{
                    background-color: {bg};
                    color: {fg};
                    border: 1px solid {fg};
                    border-radius: 4px;
                    padding: 4px 8px;
                    font-size: 11px;
                    font-weight: bold;
                    text-align: left;
                }}
                QPushButton:hover {{
                    background-color: #2C2D35;
                }}
            """)

            self.layer_modified_signal.emit(info)
            self.layer_selected_signal.emit(info)

    def _on_font_badge_clicked(self):
        if self.current_layer_info:
            self.badge_clicked_signal.emit(self.current_layer_info)

    def update_from_canvas_move(self, info):
        """画布拖拽坐标回显到 SpinBox"""
        if self.current_layer_info and self.current_layer_info.index == info.index:
            self.spin_x.blockSignals(True)
            self.spin_y.blockSignals(True)
            self.spin_x.setValue(info.motion_pos[0])
            self.spin_y.setValue(info.motion_pos[1])
            self.spin_x.blockSignals(False)
            self.spin_y.blockSignals(False)

    def _on_text_edited(self):
        if self.current_layer_info:
            self.current_layer_info.text = self.text_edit.toPlainText()
            self.layer_modified_signal.emit(self.current_layer_info)

    def _on_pos_edited(self):
        if self.current_layer_info:
            self.current_layer_info.motion_pos = (self.spin_x.value(), self.spin_y.value())
            self.layer_modified_signal.emit(self.current_layer_info)

    def _on_font_edited(self):
        if self.current_layer_info:
            self.current_layer_info.font_name = self.font_line.text()

    def _on_size_edited(self):
        if self.current_layer_info:
            self.current_layer_info.font_size = self.size_spin.value()
            self.layer_modified_signal.emit(self.current_layer_info)
