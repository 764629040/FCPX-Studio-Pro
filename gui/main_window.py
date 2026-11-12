"""
PyQt6 主窗口组件 (拖拽导入与转换诊断闭环增强版)
整合三大引擎：
1. PSD 转档与 Motion 属性设计器 (所见即所得画布 + 发布参数控制 + 拖拽导入 + 基础信息条)
2. FCPX 全能素材库与外置管理中心 (软链接外置化 + 用户级 ⇄ 外置盘)
3. PSD 转换诊断报告体系 (图层处置指标、风险评估、明细查看、JSON 报告导出)
"""
import os
import json
from PyQt6.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QTabWidget, 
    QListWidget, QListWidgetItem, QPushButton, QFileDialog, 
    QMessageBox, QLabel, QTableWidget, QTableWidgetItem, 
    QHeaderView, QFrame, QSplitter, QProgressDialog, QApplication
)
from PyQt6.QtCore import Qt, QSettings
from PyQt6.QtGui import QIcon, QColor

from core.psd_parser import (
    parse_psd_file,
    generate_conversion_diagnosis_report,
    export_diagnosis_json,
    PSDParseError
)
from core.motion_builder import MotionBuilder
from core.png_layer_io import (
    is_png_split_dir,
    parse_png_split_dir,
    regenerate_thumbnails,
    PngSplitParseError,
)
from core.thumbnail import generate_thumbnails_from_psd
from core.symlink_manager import SymlinkManager
from core.batch_runner import BatchRunner

from .canvas_view import CanvasContainer
from .inspector_panel import InspectorPanel
from .asset_hub_panel import AssetHubPanel

DEFAULT_EXTERNAL_DIR = os.path.expanduser("~/Movies/Motion Templates.localized/Titles.localized/FCPX_Studio_MVP")
DEFAULT_PSD_DIR = os.path.expanduser("~/Downloads")

# TR-009 #2：分类路径拼接禁止重复拼 Titles.localized/Templates 一层
_KNOWN_CATEGORIES = ["Titles.localized", "Effects.localized",
                    "Transitions.localized", "Generators.localized"]


def _resolve_export_group_dir(base: str, group_name: str) -> str:
    """
    由 external_root / 默认目录推导出“分组目录”（<...>/<category>/<group_name>），
    且保证分类层（Titles.localized 等）只出现一次：
      - 若 base 已含某个分类段，则截取到该分类段，再拼 group_name；
      - 否则 base 视为 Motion Templates 根，拼 base/Titles.localized/group_name。
    """
    base = os.path.normpath(base)
    parts = base.split(os.sep)
    if any(c in parts for c in _KNOWN_CATEGORIES):
        idx = max(i for i, c in enumerate(parts) if c in _KNOWN_CATEGORIES)
        return os.path.join(os.sep.join(parts[: idx + 1]), group_name)
    return os.path.join(base, "Titles.localized", group_name)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("FCPX Studio Pro - 婚礼字幕设计与外置资产管理中心")
        self.resize(1400, 900)

        self.symlink_mgr = SymlinkManager(DEFAULT_EXTERNAL_DIR)
        self.motion_builder = MotionBuilder()
        self.current_parsed_psd = None
        self.current_psd_path = None
        # D-2/D-3：当前正在编辑（或最近构建）的 .moti 路径，供拖拽/锁定实时写回
        self.current_moti_path = None
        self.psd_file_list = []
        self.settings = QSettings("FCPXStudioPro", "FCPXStudioPro")
        self._init_theme()
        self._init_ui()

        # 开启窗口原生拖拽 (Drag & Drop) 支持
        self.setAcceptDrops(True)

        # 智能探测并加载默认素材目录 (QSettings 记忆优先 -> /Volumes/NO NAME/128/字幕 -> tests/data -> ~/Downloads)
        saved_dir = self.settings.value("psd_asset_dir", "")
        if saved_dir and os.path.exists(saved_dir):
            self.current_asset_dir = saved_dir
        elif os.path.exists("/Volumes/NO NAME/128/字幕"):
            self.current_asset_dir = "/Volumes/NO NAME/128/字幕"
        else:
            local_data = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests", "data")
            self.current_asset_dir = local_data if os.path.exists(local_data) else DEFAULT_PSD_DIR

        if os.path.exists(self.current_asset_dir):
            self._load_psd_dir(self.current_asset_dir)

    def _init_theme(self):
        self.setStyleSheet("""
            QMainWindow {
                background-color: #121316;
            }
            QTabWidget::pane {
                border: 1px solid #262830;
                background-color: #141519;
                border-radius: 8px;
            }
            QTabBar::tab {
                background: #1C1E24;
                color: #A0A4B0;
                padding: 8px 24px;
                font-weight: 500;
                border: 1px solid #2B2D35;
                border-bottom: none;
                border-top-left-radius: 6px;
                border-top-right-radius: 6px;
                margin-right: 4px;
            }
            QTabBar::tab:selected {
                background: #272A34;
                color: #FFFFFF;
                font-weight: bold;
                border-color: #0A84FF;
            }
            QListWidget {
                background-color: #16171B;
                border: 1px solid #2B2D35;
                border-radius: 8px;
                color: #FFFFFF;
            }
            QListWidget::item {
                padding: 8px;
                border-bottom: 1px solid #20222A;
            }
            QListWidget::item:selected {
                background-color: #242732;
                border-left: 3px solid #0A84FF;
            }
        """)

    def _init_ui(self):
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setContentsMargins(12, 12, 12, 12)
        main_layout.setSpacing(8)

        # ── 顶部基础信息条 (PSD 元数据与健康状态) ──
        self.info_banner = QFrame()
        self.info_banner.setStyleSheet("""
            QFrame {
                background-color: #181A20;
                border: 1px solid #2B2D35;
                border-radius: 8px;
                padding: 6px 12px;
            }
        """)
        banner_layout = QHBoxLayout(self.info_banner)
        banner_layout.setContentsMargins(8, 4, 8, 4)

        self.lbl_file_name = QLabel("当前文件: 未加载 (支持直接拖拽 PSD 文件或文件夹至此)")
        self.lbl_file_name.setStyleSheet("font-weight: bold; color: #FFFFFF; font-size: 13px;")
        banner_layout.addWidget(self.lbl_file_name)

        banner_layout.addStretch()

        self.lbl_resolution = QLabel("分辨率: --")
        self.lbl_resolution.setStyleSheet("color: #A0A4B0; font-size: 12px; margin-right: 12px;")
        banner_layout.addWidget(self.lbl_resolution)

        self.lbl_aspect_ratio = QLabel("画幅: --")
        self.lbl_aspect_ratio.setStyleSheet("color: #A0A4B0; font-size: 12px; margin-right: 12px;")
        banner_layout.addWidget(self.lbl_aspect_ratio)

        self.lbl_layer_count = QLabel("图层数: --")
        self.lbl_layer_count.setStyleSheet("color: #0A84FF; font-weight: bold; font-size: 12px; margin-right: 12px;")
        banner_layout.addWidget(self.lbl_layer_count)

        self.lbl_risk_badge = QLabel("状态: 就绪")
        self.lbl_risk_badge.setStyleSheet("background-color: #232733; color: #30D158; padding: 3px 8px; border-radius: 4px; font-size: 11px;")
        banner_layout.addWidget(self.lbl_risk_badge)

        main_layout.addWidget(self.info_banner)

        # ── 错误提示条 (容错状态展现) ──
        self.error_banner = QFrame()
        self.error_banner.setVisible(False)
        self.error_banner.setStyleSheet("""
            QFrame {
                background-color: #2D1417;
                border: 1px solid #FF453A;
                border-radius: 8px;
                padding: 8px 14px;
            }
        """)
        err_layout = QHBoxLayout(self.error_banner)
        err_layout.setContentsMargins(4, 4, 4, 4)
        self.lbl_error_msg = QLabel("⚠️ 文件解析异常")
        self.lbl_error_msg.setStyleSheet("color: #FF453A; font-weight: bold; font-size: 12px;")
        err_layout.addWidget(self.lbl_error_msg)
        main_layout.addWidget(self.error_banner)

        # ── PNG 智能拆分（P1）链路的口径横幅：文字层是位图，能挪不能改 ──
        # 立项单 §2/§8 要求这一句必须写在界面上，不许让用户以为能改字。
        self.bitmap_notice_banner = QFrame()
        self.bitmap_notice_banner.setVisible(False)
        self.bitmap_notice_banner.setStyleSheet("""
            QFrame {
                background-color: #2A2312;
                border: 1px solid #FF9F0A;
                border-radius: 8px;
                padding: 8px 14px;
            }
        """)
        notice_layout = QHBoxLayout(self.bitmap_notice_banner)
        notice_layout.setContentsMargins(4, 4, 4, 4)
        self.lbl_bitmap_notice = QLabel("位图文字：文字层能挪不能改")
        self.lbl_bitmap_notice.setStyleSheet(
            "color: #FF9F0A; font-weight: bold; font-size: 12px;")
        self.lbl_bitmap_notice.setWordWrap(True)
        notice_layout.addWidget(self.lbl_bitmap_notice)
        main_layout.addWidget(self.bitmap_notice_banner)

        # ── 主 Tab 分页 ──
        self.tab_widget = QTabWidget()
        main_layout.addWidget(self.tab_widget)

        # Tab 1: PSD 转档与 Motion 属性设计器
        tab1_widget = QWidget()
        tab1_layout = QHBoxLayout(tab1_widget)
        tab1_layout.setContentsMargins(6, 6, 6, 6)

        # 左栏：PSD 批量列表
        left_box = QWidget()
        left_layout = QVBoxLayout(left_box)
        left_layout.setContentsMargins(0, 0, 0, 0)
        
        left_title_bar = QHBoxLayout()
        left_title = QLabel("素材列表")
        left_title.setStyleSheet("font-weight: bold; color: #E0E2E8; font-size: 12px;")
        left_title_bar.addWidget(left_title)

        self.change_dir_btn = QPushButton("📂 更改目录")
        self.change_dir_btn.setStyleSheet("background-color: #242732; color: #E0E2E8; padding: 4px 6px; border-radius: 4px; font-size: 11px;")
        self.change_dir_btn.clicked.connect(self._on_change_dir_clicked)
        left_title_bar.addWidget(self.change_dir_btn)
        
        self.import_btn = QPushButton("+ 导入")
        self.import_btn.setStyleSheet("background-color: #0A84FF; color: white; padding: 4px 6px; border-radius: 4px; font-size: 11px;")
        self.import_btn.clicked.connect(self._on_import_folder_clicked)
        left_title_bar.addWidget(self.import_btn)
        left_layout.addLayout(left_title_bar)

        self.psd_list_widget = QListWidget()
        self.psd_list_widget.currentRowChanged.connect(self._on_psd_selected)
        left_layout.addWidget(self.psd_list_widget)
        left_box.setFixedWidth(240)
        tab1_layout.addWidget(left_box)

        # 中栏：并排双视界与限定画板
        self.canvas_view = CanvasContainer()
        self.canvas_view.layer_moved_signal.connect(self._on_canvas_layer_moved)
        self.canvas_view.layer_committed_signal.connect(self._on_canvas_layer_committed)
        self.canvas_view.badge_clicked_signal.connect(self._on_jump_to_diagnosis)
        self.canvas_view.region_picked_signal.connect(self._on_region_picked)
        self.canvas_view.region_cancelled_signal.connect(self._on_region_cancelled)
        tab1_layout.addWidget(self.canvas_view, stretch=3)

        # 右栏：属性面板
        self.inspector = InspectorPanel()
        self.inspector.layer_modified_signal.connect(self._on_inspector_layer_modified)
        self.inspector.layer_selected_signal.connect(self.canvas_view.select_layer)
        self.inspector.badge_clicked_signal.connect(self._on_jump_to_diagnosis)
        self.inspector.layers_merge_requested.connect(self._on_merge_layers)
        self.inspector.layer_split_requested.connect(self._on_split_layer)
        self.inspector.layer_region_split_requested.connect(self._on_begin_region_split)
        self.inspector.save_template_signal.connect(self._on_save_current_template)
        self.inspector.batch_export_signal.connect(self._on_batch_export_all)
        self.inspector.setFixedWidth(400)  # 层树 5 列，360 时图层名只剩几个字看不清
        tab1_layout.addWidget(self.inspector)

        self.tab_widget.addTab(tab1_widget, "🎨 引擎一：PSD 转档与 Motion 属性设计器")

        # Tab 2: FCPX 全能素材库与外置管理中心
        self.asset_hub = AssetHubPanel(self.symlink_mgr)
        self.asset_hub.open_template_in_designer.connect(self._on_back_to_designer)
        self.tab_widget.addTab(self.asset_hub, "📦 引擎二：FCPX 全能素材库与外置管理中心")

        # Tab 3: PSD 转换诊断报告 (核心闭环)
        self.diag_tab = QWidget()
        self._init_diagnosis_tab()
        self.tab_widget.addTab(self.diag_tab, "📊 引擎三：PSD 转换诊断与报告 (闭环中心)")

    def _init_diagnosis_tab(self):
        layout = QVBoxLayout(self.diag_tab)
        layout.setContentsMargins(12, 12, 12, 12)
        layout.setSpacing(10)

        # 1. 顶部全局指标卡片栏
        cards_layout = QHBoxLayout()
        cards_layout.setSpacing(10)

        self.card_total = self._create_metric_card("扫描图层总数", "0", "#E0E2E8")
        self.card_preserved = self._create_metric_card("保留矢量文字", "0", "#30D158")
        self.card_degraded = self._create_metric_card("降级透明贴图", "0", "#FF9F0A")
        self.card_ignored = self._create_metric_card("已忽略/空/组", "0", "#8E8E93")
        self.card_fonts = self._create_metric_card("缺字体/缺字形", "0", "#FF453A")
        self.card_risk = self._create_metric_card("风险评估状态", "就绪", "#30D158")

        cards_layout.addWidget(self.card_total)
        cards_layout.addWidget(self.card_preserved)
        cards_layout.addWidget(self.card_degraded)
        cards_layout.addWidget(self.card_ignored)
        cards_layout.addWidget(self.card_fonts)
        cards_layout.addWidget(self.card_risk)
        layout.addLayout(cards_layout)

        # 2. 图层处置明细表
        self.diag_table = QTableWidget()
        self.diag_table.setColumnCount(6)
        self.diag_table.setHorizontalHeaderLabels([
            "图层路径", "图层类型", "处置方案", "具体处置原因", "字体状态 / 缺失字形", "未保留特性 / 样式"
        ])
        self.diag_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.diag_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.diag_table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        self.diag_table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeMode.Stretch)
        self.diag_table.horizontalHeader().setSectionResizeMode(4, QHeaderView.ResizeMode.ResizeToContents)
        self.diag_table.horizontalHeader().setSectionResizeMode(5, QHeaderView.ResizeMode.ResizeToContents)
        self.diag_table.setStyleSheet("""
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
                font-weight: bold;
            }
            QTableWidget::item {
                padding: 4px;
                border-bottom: 1px solid #20222A;
            }
        """)
        layout.addWidget(self.diag_table, stretch=1)

        # 3. 底部导出按钮栏
        bottom_bar = QHBoxLayout()
        self.diag_path_label = QLabel("当前报告源文件: 未加载")
        self.diag_path_label.setStyleSheet("color: #8E8E93; font-size: 12px;")
        bottom_bar.addWidget(self.diag_path_label)

        bottom_bar.addStretch()

        self.btn_export_json = QPushButton("📥 导出标准 JSON 转换诊断报告")
        self.btn_export_json.setStyleSheet("""
            QPushButton {
                background-color: #0A84FF;
                color: white;
                font-weight: bold;
                padding: 8px 16px;
                border-radius: 6px;
            }
            QPushButton:hover {
                background-color: #0071E3;
            }
        """)
        self.btn_export_json.clicked.connect(self._on_export_diagnosis_json_clicked)
        bottom_bar.addWidget(self.btn_export_json)

        layout.addLayout(bottom_bar)

    def _create_metric_card(self, title: str, value: str, color_hex: str) -> QFrame:
        card = QFrame()
        card.setStyleSheet(f"""
            QFrame {{
                background-color: #181A20;
                border: 1px solid #2B2D35;
                border-radius: 8px;
                padding: 8px;
            }}
        """)
        card_l = QVBoxLayout(card)
        card_l.setContentsMargins(6, 4, 6, 4)
        card_l.setSpacing(2)

        lbl_t = QLabel(title)
        lbl_t.setStyleSheet("color: #8E8E93; font-size: 11px;")
        card_l.addWidget(lbl_t)

        lbl_v = QLabel(value)
        lbl_v.setStyleSheet(f"color: {color_hex}; font-size: 18px; font-weight: bold;")
        card_l.addWidget(lbl_v)
        card.lbl_val = lbl_v
        return card

    # ── 拖拽 (Drag & Drop) 事件处理 ──
    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()
        else:
            event.ignore()

    def dropEvent(self, event):
        urls = event.mimeData().urls()
        psd_paths = []
        for u in urls:
            local_p = u.toLocalFile()
            if os.path.isdir(local_p):
                for root, _, files in os.walk(local_p):
                    for f in sorted(files):
                        if f.endswith(".psd") and not f.startswith("."):
                            psd_paths.append(os.path.join(root, f))
            elif os.path.isfile(local_p) and local_p.endswith(".psd"):
                psd_paths.append(local_p)

        if psd_paths:
            self._append_psd_files(psd_paths)
            event.acceptProposedAction()

    def _append_psd_files(self, paths):
        added_count = 0
        for p in paths:
            if p not in self.psd_file_list:
                self.psd_file_list.append(p)
                is_split = os.path.isdir(p)
                item = QListWidgetItem(
                    ("🖼️ %s" % os.path.basename(p)) if is_split
                    else ("📄 %s" % os.path.basename(p)))
                if is_split:
                    item.setToolTip("%s\nPNG 智能拆分输出目录（位图文字：能挪不能改）" % p)
                self.psd_list_widget.addItem(item)
                added_count += 1
        if added_count > 0:
            # 自动切换至首个新导入的文件
            new_idx = len(self.psd_file_list) - added_count
            self.psd_list_widget.setCurrentRow(new_idx)

    def _load_psd_dir(self, dir_path):
        self.psd_list_widget.clear()
        self.psd_file_list = []
        if not os.path.exists(dir_path):
            return
        # 直接选中的就是 PNG 拆分输出目录：单条载入
        if is_png_split_dir(dir_path):
            self._append_psd_files([dir_path])
            return
        files = sorted(os.listdir(dir_path))
        for f in files:
            if f.endswith(".psd") and not f.startswith("."):
                full_p = os.path.join(dir_path, f)
                self.psd_file_list.append(full_p)
                item = QListWidgetItem(f"📄 {f}")
                self.psd_list_widget.addItem(item)
                continue
            # 子目录里若是 PNG 智能拆分（P1）的输出目录，也当成一个可载入项
            sub = os.path.join(dir_path, f)
            if not f.startswith(".") and os.path.isdir(sub) and is_png_split_dir(sub):
                self.psd_file_list.append(sub)
                item = QListWidgetItem(f"🖼️ {f}")
                item.setToolTip("%s\nPNG 智能拆分输出目录（位图文字：能挪不能改）" % sub)
                self.psd_list_widget.addItem(item)
        if self.psd_file_list:
            self.psd_list_widget.setCurrentRow(0)

    def _on_import_folder_clicked(self):
        dir_p = QFileDialog.getExistingDirectory(
            self, "选择包含 PSD 文件或 PNG 拆分输出目录的目录")
        if dir_p:
            self._load_psd_dir(dir_p)

    def _on_psd_selected(self, row):
        if 0 <= row < len(self.psd_file_list):
            self.current_psd_path = self.psd_file_list[row]
            is_split = os.path.isdir(self.current_psd_path)
            file_name = os.path.basename(self.current_psd_path)

            try:
                # 调用核心解析与诊断引擎
                if is_split:
                    self.current_parsed_psd = parse_png_split_dir(self.current_psd_path)
                else:
                    self.current_parsed_psd = parse_psd_file(
                        self.current_psd_path,
                        extract_fallback_pngs=False,
                        extract_thumbnails=True
                    )
                self.error_banner.setVisible(False)

                # PNG 链路必须把「文字能挪不能改」摆在明面上（立项单 §2/§8）
                notice = self.current_parsed_psd.get("bitmap_text_notice")
                if notice:
                    self.lbl_bitmap_notice.setText(
                        "🖼️ %s —— 本条链路不提供可编辑文本；要真文字请走 PSD 链路" % notice)
                    self.bitmap_notice_banner.setVisible(True)
                else:
                    self.bitmap_notice_banner.setVisible(False)

                # 刷新顶部 Banner
                self.lbl_file_name.setText(f"📄 {self.current_parsed_psd['file_name']}")
                self.lbl_file_name.setToolTip(self.current_psd_path)
                self.lbl_resolution.setText(f"分辨率: {self.current_parsed_psd['width']}×{self.current_parsed_psd['height']}")
                self.lbl_aspect_ratio.setText(f"画幅: {self.current_parsed_psd['aspect_ratio_str']}")
                self.lbl_layer_count.setText(
                    f"图层数: 参与转换 {self.current_parsed_psd['layer_count']} / 文档总计 {self.current_parsed_psd['total_layers_count']}"
                )

                # 刷新诊断报告
                diag_report = self.current_parsed_psd.get("diagnosis_report")
                self.current_diagnosis_report = diag_report
                if diag_report:
                    summary = diag_report["summary"]
                    has_risk = summary.get("has_missing_risk", False)
                    if summary.get("failed_count", 0) > 0:
                        self.lbl_risk_badge.setText("⚠️ 存在解析失败")
                        self.lbl_risk_badge.setStyleSheet("background-color: #3D1418; color: #FF453A; padding: 3px 8px; border-radius: 4px;")
                    elif has_risk:
                        self.lbl_risk_badge.setText("⚠️ 存在缺字/回退风险")
                        self.lbl_risk_badge.setStyleSheet("background-color: #3D2914; color: #FF9F0A; padding: 3px 8px; border-radius: 4px;")
                    else:
                        self.lbl_risk_badge.setText("✅ 诊断健康 (100% 覆盖)")
                        self.lbl_risk_badge.setStyleSheet("background-color: #14301C; color: #30D158; padding: 3px 8px; border-radius: 4px;")

                    self._populate_diagnosis_tab(diag_report)

                # 载入画布与面板
                layers = self.current_parsed_psd["layers"]
                layer_tree = self.current_parsed_psd.get("layer_tree")
                # 画板必须先跟文档真实尺寸对齐：否则竖版文档按 1920×1080 的画板
                # 摆放 1080×1920 的层坐标，整幅就错位溢出。
                self.canvas_view.set_artboard_resolution(
                    self.current_parsed_psd["width"], self.current_parsed_psd["height"])
                self.canvas_view.load_layers(layers)
                self.inspector.load_layers(layers, layer_tree=layer_tree)

            except PSDParseError as err:
                # 结构化捕获单文件损坏异常，精准定位源文件，界面显示红色警报面板，绝不崩溃！
                err_text = f"文件损坏或格式非法: [{err.file_name}] - {str(err.original_error)}"
                self._show_error_state(err.file_name, err.file_path, err_text)
            except PngSplitParseError as err:
                # 分层目录不可用 / 清单损坏：同样走可读提示，不改源文件、不进写回
                err_text = f"分层目录不可用: [{err.file_name}] - {str(err.original_error)}"
                self._show_error_state(err.file_name, err.file_path, err_text)
            except Exception as e:
                err_text = f"读取异常: [{file_name}] - {str(e)}"
                self._show_error_state(file_name, self.current_psd_path, err_text)

    def _show_error_state(self, file_name, file_path, error_msg):
        """展示友好错误面板并保留已有列表，不影响后续交互"""
        self.error_banner.setVisible(True)
        self.lbl_error_msg.setText(f"❌ {error_msg}")
        self.lbl_file_name.setText(f"❌ 损坏文件: {file_name}")
        self.lbl_resolution.setText("分辨率: 无法解析")
        self.lbl_aspect_ratio.setText("画幅: 未知")
        self.lbl_layer_count.setText("图层数: 0")
        self.lbl_risk_badge.setText("❌ 解析失败")
        self.lbl_risk_badge.setStyleSheet("background-color: #3D1418; color: #FF453A; padding: 3px 8px; border-radius: 4px;")

        # 生成失败诊断报告（PNG 分层目录没有 PSD 报告可生成，只留失败态）
        if os.path.isdir(file_path):
            self.current_diagnosis_report = None
            self._populate_diagnosis_tab({"summary": {}, "layers": [], "warnings": [error_msg], "notes": []})
            return
        fail_report = generate_conversion_diagnosis_report(file_path)
        self.current_diagnosis_report = fail_report
        self._populate_diagnosis_tab(fail_report)

    def _populate_diagnosis_tab(self, report: dict):
        summary = report.get("summary", {})
        self.card_total.lbl_val.setText(str(summary.get("total_layers", 0)))
        self.card_preserved.lbl_val.setText(str(summary.get("preserved_count", 0)))
        self.card_degraded.lbl_val.setText(str(summary.get("degraded_count", 0)))
        self.card_ignored.lbl_val.setText(str(summary.get("ignored_count", 0)))
        self.card_fonts.lbl_val.setText(str(summary.get("missing_fonts_count", 0)))
        
        risk_text = summary.get("risk_assessment", "未知")
        self.card_risk.lbl_val.setText(risk_text.split("：")[0])
        self.card_risk.setToolTip(risk_text)

        # A-6 修复：标题、页脚、导出 JSON 三处源文件标识必须同源。
        # 统一取诊断报告 summary.source_file，并同步刷新窗口标题栏尾部，
        # 避免出现"标题写 A.psd、页脚写 four_state.psd"这类不一致。
        src_info = summary.get("source_file", {}) or {}
        src_name = src_info.get("name") or "未知"
        src_path = src_info.get("path") or ""
        self.current_source_name = src_name
        self.diag_path_label.setText(f"当前报告源文件: {src_name} ({src_path})")
        self.setWindowTitle(
            f"FCPX Studio Pro - 婚礼字幕设计与外置资产管理中心 — {src_name}"
        )

        # 填充表格
        layers = report.get("layers", [])
        self.diag_table.setRowCount(len(layers))

        disp_colors = {
            "preserved": ("#14301C", "#30D158"),
            "degraded": ("#3D2914", "#FF9F0A"),
            "ignored": ("#23242A", "#8E8E93"),
            "failed": ("#3D1418", "#FF453A")
        }

        for row, l in enumerate(layers):
            path_item = QTableWidgetItem(l.get("layer_path", ""))
            l_idx = l.get("layer_index")
            if l_idx is not None:
                path_item.setData(Qt.ItemDataRole.UserRole, l_idx)
            self.diag_table.setItem(row, 0, path_item)
            self.diag_table.setItem(row, 1, QTableWidgetItem(f"[{l.get('layer_type', '')}]"))

            disp = l.get("disposition", "ignored")
            disp_item = QTableWidgetItem(disp.upper())
            bg, fg = disp_colors.get(disp, ("#23242A", "#FFF"))
            disp_item.setBackground(QColor(bg))
            disp_item.setForeground(QColor(fg))
            self.diag_table.setItem(row, 2, disp_item)

            self.diag_table.setItem(row, 3, QTableWidgetItem(l.get("reason", "")))

            f_stat = l.get("font_status") or "--"
            miss_g = l.get("missing_glyphs", [])
            miss_str = f" (缺 {len(miss_g)} 字)" if miss_g else ""
            self.diag_table.setItem(row, 4, QTableWidgetItem(f"{f_stat}{miss_str}"))

            unsupported = l.get("unsupported_features", [])
            unsupp_str = " | ".join(unsupported) if unsupported else "--"
            self.diag_table.setItem(row, 5, QTableWidgetItem(unsupp_str))

    def _on_export_diagnosis_json_clicked(self):
        if not self.current_diagnosis_report:
            QMessageBox.warning(self, "提示", "当前没有可导出的诊断报告！")
            return

        src_name = self.current_diagnosis_report.get("summary", {}).get("source_file", {}).get("name", "report")
        base_name = os.path.splitext(src_name)[0]
        default_file = f"diagnosis_{base_name}.json"

        save_p, _ = QFileDialog.getSaveFileName(self, "保存 JSON 转换诊断报告", default_file, "JSON Files (*.json)")
        if save_p:
            export_diagnosis_json(self.current_diagnosis_report, save_p)
            QMessageBox.information(self, "导出成功", f"JSON 转换诊断报告已成功导出至:\n{save_p}")

    def _on_canvas_layer_moved(self, info):
        self.inspector.update_from_canvas_move(info)

    def _on_canvas_layer_committed(self, info):
        # D-2：拖拽落定已写回 .moti；这里同步刷新 Inspector 坐标显示。
        self.inspector.update_from_canvas_move(info)

    def _on_inspector_layer_modified(self, info):
        self.canvas_view.update_layer_display(info)

    # ── 面板手动合并 / 拆分（P2-b）──
    def _layer_edit_ready(self) -> bool:
        """只有 PNG 分层链路可编辑：PSD 的层来自源文件，在这里改了跟源对不上。"""
        if not self.current_parsed_psd or not self.current_psd_path:
            QMessageBox.warning(self, "提示", "请先选择一个已拆分好的 PNG 分层目录！")
            return False
        if self.current_parsed_psd.get("source_kind") != "png_split":
            QMessageBox.warning(self, "提示",
                                "手动合并/拆分只支持 PNG 分层目录；PSD 的层来自源文件，不能在这里改。")
            return False
        return True

    def _apply_layer_edit(self, res):
        """层表整体换掉并重刷画布与面板；同时写回磁盘，让改动永久生效。"""
        new_layers, msg = res
        if new_layers is None:
            QMessageBox.warning(self, "改不了", msg)
            return
        from core.png_layer_io import persist_layer_edit

        parsed = self.current_parsed_psd
        # 先落盘再改界面：写不进去就整体不动，避免"界面改了但文件没改"的半截状态
        persisted, pmsg = persist_layer_edit(parsed, self.current_psd_path, new_layers)
        if persisted is None:
            QMessageBox.warning(self, "写回失败", pmsg + "\n\n磁盘和界面都没有改动。")
            return
        parsed["layers"] = persisted
        parsed["layer_count"] = len(persisted)
        parsed["low_confidence_layers"] = [
            l.name for l in persisted if (l.fallback_png_info or {}).get("low_confidence")
        ]
        self.lbl_layer_count.setText(
            f"图层数: 参与转换 {len(persisted)} / 文档总计 {parsed['total_layers_count']}"
        )
        # 层结构整表变了：画布本就是全量重建，按新表刷最稳
        self.canvas_view.load_layers(persisted)
        self.inspector.load_layers(persisted, layer_tree=parsed.get("layer_tree"))
        self.statusBar().showMessage(pmsg, 5000)

    def _on_merge_layers(self, indexes):
        if not self._layer_edit_ready():
            return
        from core.png_layer_io import merge_layer_models
        self._apply_layer_edit(
            merge_layer_models(self.current_parsed_psd, self.current_psd_path, indexes))

    def _on_split_layer(self, index):
        if not self._layer_edit_ready():
            return
        from core.png_layer_io import split_layer_model
        self._apply_layer_edit(
            split_layer_model(self.current_parsed_psd, self.current_psd_path, index))

    def _on_begin_region_split(self, index):
        """进入框选模式：真正的拆分等用户在右侧画板拖完框才发生。"""
        if not self._layer_edit_ready():
            return
        target = next((l for l in self.current_parsed_psd["layers"] if l.index == int(index)), None)
        if target is None:
            QMessageBox.warning(self, "改不了", "选中的层已不存在")
            return
        if (target.fallback_png_info or {}).get("layer_class") == "BACKGROUND":
            QMessageBox.warning(self, "改不了", "背景层不拆（拆开没有意义）")
            return
        self.canvas_view.begin_region_split(index)

    def _on_region_picked(self, index, rect):
        if not self._layer_edit_ready():
            return
        from core.png_layer_io import split_layer_model
        self._apply_layer_edit(
            split_layer_model(self.current_parsed_psd, self.current_psd_path, index, region=rect))

    def _on_region_cancelled(self):
        # 用户按 Esc 或点了右键：静默退出，不打扰
        pass

    def _on_save_current_template(self):
        if not self.current_parsed_psd or not self.current_psd_path:
            QMessageBox.warning(self, "提示", "请先选择一个有效的 PSD 文件或 PNG 拆分目录！")
            return

        is_split = os.path.isdir(self.current_psd_path)
        base_name = (os.path.basename(self.current_psd_path.rstrip(os.sep)) if is_split
                     else os.path.splitext(os.path.basename(self.current_psd_path))[0])
        group_name = "PSD婚礼字幕"
        target_group_dir = _resolve_export_group_dir(self.symlink_mgr.external_root or DEFAULT_EXTERNAL_DIR, group_name)
        template_dir = os.path.join(target_group_dir, base_name)

        # ── R21-T2：冲突预检回调（core 层不弹 GUI，由这里注入）──
        def _on_conflict(path):
            ret = QMessageBox.question(
                self, "模板已存在",
                f"目标模板目录已存在且非空:\n{path}\n\n"
                f"是否覆盖？原版本将被自动备份。",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,  # 默认取消
            )
            return ret == QMessageBox.StandardButton.Yes

        try:
            build_res = self.motion_builder.build_template_atomic(
                layers_info=self.current_parsed_psd["layers"],
                output_dir=template_dir,
                template_name=base_name,
                # PNG 链路没有 PSD 源：传 None，模板里全部走 Media 位图层
                psd_path=None if is_split else self.current_psd_path,
                backup_existing=True,
                # A-24：必须传真实画布尺寸，否则竖版 PSD 会生成横版 comp
                canvas_size=(self.current_parsed_psd["width"],
                             self.current_parsed_psd["height"]),
                # R21-T2：冲突时弹确认框，默认取消
                on_conflict="ask",
                conflict_callback=_on_conflict,
            )
            if is_split:
                # 没有 PSD 时 build_template_atomic 会写全透明占位缩略图，用源成品图补回来
                regenerate_thumbnails(self.current_parsed_psd, template_dir)

            # D-2/D-3：构建完成后，把 .moti 路径下发给画布与检查器，
            # 之后的拖拽/隐藏/锁定都会实时写回这个文件。
            self.current_moti_path = os.path.join(template_dir, base_name + ".moti")
            self.canvas_view.set_moti_path(self.current_moti_path)
            self.inspector.set_moti_path(self.current_moti_path)

            self.symlink_mgr.link_category_to_system("Titles.localized", group_name)

            bak_info = f"\n(原版本已安全备份至: {os.path.basename(build_res['backup_path'])})" if build_res.get("backup_path") else ""
            QMessageBox.information(self, "成功", f"模板已通过原子沙箱安全导出并挂载至 FCPX:\n{template_dir}{bak_info}")
            self.asset_hub.refresh_plugins()
        except Exception as e:
            QMessageBox.critical(self, "导出失败", f"原子构建模板异常已自动安全回滚:\n{str(e)}")

    def _build_one_template(self, psd_path, template_dir, template_name):
        """批量执行器单元：解析 PSD 并原子构建单套模板（与单模板保存同源）"""
        parsed = parse_psd_file(psd_path)
        self.motion_builder.build_template_atomic(
            layers_info=parsed["layers"],
            output_dir=template_dir,
            template_name=template_name,
            canvas_size=(parsed["width"], parsed["height"]),
            psd_path=psd_path,
            backup_existing=True,
        )
        self.current_moti_path = os.path.join(template_dir, template_name + ".moti")
        self.canvas_view.set_moti_path(self.current_moti_path)
        self.inspector.set_moti_path(self.current_moti_path)

    def _on_batch_export_all(self):
        if not self.psd_file_list:
            QMessageBox.warning(self, "提示", "列表中没有可导出的 PSD 文件！")
            return

        group_name = "PSD婚礼字幕"
        target_group_dir = _resolve_export_group_dir(self.symlink_mgr.external_root or DEFAULT_EXTERNAL_DIR, group_name)
        os.makedirs(target_group_dir, exist_ok=True)
        # 状态文件落在输出分组目录（非 128 审核卷，满足 core 不写源卷约束）
        state_path = os.path.join(target_group_dir, ".batch_state.json")

        items = []
        for psd_p in self.psd_file_list:
            base_name = os.path.splitext(os.path.basename(psd_p))[0]
            template_dir = os.path.join(target_group_dir, base_name)
            items.append((psd_p, template_dir))

        prior = BatchRunner._load(state_path)
        has_unfinished = bool(prior) and any(
            it["status"] in ("pending", "failed") for it in prior["items"]
        )
        mode = self._ask_batch_resume_mode(prior) if has_unfinished else "new"

        final_state = self._run_batch_with_progress(items, state_path, mode)

        self.symlink_mgr.link_category_to_system("Titles.localized", group_name)
        self.asset_hub.refresh_plugins()
        self._report_batch_result(final_state)

    def _make_batch_executor(self):
        """执行器闭包：每完成一项更新进度条，并支持用户取消（取消后剩余项保持 pending/failed 供续跑）"""
        def executor(item):
            psd_p = item["source"]
            template_dir = item["target"]
            base_name = os.path.splitext(os.path.basename(psd_p))[0]
            try:
                self._build_one_template(psd_p, template_dir, base_name)
            except Exception:
                raise
            finally:
                self._batch_done += 1
                if self._batch_dlg:
                    self._batch_dlg.setValue(self._batch_done)
                    self._batch_dlg.setLabelText(
                        f"导出中 {self._batch_done}/{self._batch_total}：{os.path.basename(psd_p)}"
                    )
                    QApplication.processEvents()
                    if self._batch_dlg.wasCanceled():
                        raise RuntimeError("用户取消批量导出")
        return executor

    def _ask_batch_resume_mode(self, prior):
        """检测到未完成批量任务时，让用户选择续跑方式"""
        unfinished = sum(1 for it in prior["items"] if it["status"] in ("pending", "failed"))
        msg = QMessageBox(self)
        msg.setWindowTitle("检测到未完成的批量任务")
        msg.setText(
            f"发现上次批量任务状态（共 {len(prior['items'])} 项，未完成 {unfinished} 项）。\n\n"
            "请选择继续执行方式："
        )
        resume_btn = msg.addButton("续跑未完成", QMessageBox.ButtonRole.AcceptRole)
        retry_btn = msg.addButton("仅重试失败", QMessageBox.ButtonRole.ActionRole)
        new_btn = msg.addButton("重新开始", QMessageBox.ButtonRole.DestructiveRole)
        msg.exec()
        clicked = msg.clickedButton()
        if clicked == retry_btn:
            return "retry"
        if clicked == new_btn:
            return "new"
        return "resume"

    def _run_batch_with_progress(self, items, state_path, mode):
        """用 BatchRunner 执行批量，并展示模态进度条（done/total/当前）"""
        if mode == "new":
            total = len(items)
        else:
            st = BatchRunner._load(state_path)
            total = len(st["items"]) if st else len(items)
        self._batch_total = total
        self._batch_done = 0
        self._batch_dlg = QProgressDialog("准备批量导出...", "取消", 0, max(1, total), self)
        self._batch_dlg.setWindowModality(Qt.WindowModality.WindowModal)
        self._batch_dlg.setMinimumDuration(0)
        self._batch_dlg.setValue(0)

        runner = BatchRunner(self._make_batch_executor())
        try:
            if mode == "new":
                final_state = runner.run_new(items, state_path)
            elif mode == "resume":
                final_state = runner.resume_task(state_path)
            else:
                final_state = runner.retry_failed(state_path)
        finally:
            if self._batch_dlg:
                self._batch_dlg.setValue(self._batch_dlg.maximum())
                self._batch_dlg.close()
                self._batch_dlg = None
        return final_state

    def _report_batch_result(self, final_state):
        if not final_state:
            return
        counts = {"done": 0, "failed": 0, "pending": 0}
        for it in final_state["items"]:
            counts[it["status"]] = counts.get(it["status"], 0) + 1
        if counts["failed"] or counts["pending"]:
            summary = (
                f"批量导出完成：成功 {counts['done']} 套，未完成 {counts['failed'] + counts['pending']} 套"
                f"（失败 {counts['failed']} / 待处理 {counts['pending']}）。\n\n"
                "可再次点击“一键批量导出”续跑或仅重试失败项。"
            )
            QMessageBox.warning(self, "批量导出完成（含未完成项）", summary)
        else:
            QMessageBox.information(
                self, "批量导出完成",
                f"成功导出全部 {counts['done']} 套模板，并已建立 FCPX 软链接！"
            )

    def _on_back_to_designer(self, template_path):
        self.tab_widget.setCurrentIndex(0)

    def _on_change_dir_clicked(self):
        new_d = QFileDialog.getExistingDirectory(self, "选择 PSD 素材源目录", self.current_asset_dir)
        if new_d:
            self.current_asset_dir = new_d
            self.settings.setValue("psd_asset_dir", new_d)
            self._load_psd_dir(new_d)

    def _on_jump_to_diagnosis(self, layer_info):
        """点击字体/缺字徽章直接跳转定位至 Tab 3 转换诊断报告的对应图层行"""
        self.tab_widget.setCurrentIndex(2) # 切换至诊断报告 Tab
        if not layer_info:
            return

        target_idx = getattr(layer_info, "index", None)
        if target_idx is None and isinstance(layer_info, dict):
            target_idx = layer_info.get("layer_index") or layer_info.get("index")

        target_name = getattr(layer_info, "name", "") if not isinstance(layer_info, dict) else layer_info.get("name", "")
        target_path = getattr(layer_info, "layer_path", target_name) if not isinstance(layer_info, dict) else layer_info.get("layer_path", target_name)

        matched_row = -1
        # 1. 优先按唯一数字索引 layer_index 精准比对
        if target_idx is not None:
            for row in range(self.diag_table.rowCount()):
                path_item = self.diag_table.item(row, 0)
                if path_item and path_item.data(Qt.ItemDataRole.UserRole) == target_idx:
                    matched_row = row
                    break

        # 2. 若未命中则降级比对完整路径精确全等 target_path（坚决杜绝任何模糊包含匹配！）
        if matched_row == -1 and target_path:
            for row in range(self.diag_table.rowCount()):
                path_item = self.diag_table.item(row, 0)
                if path_item and path_item.text() == target_path:
                    matched_row = row
                    break

        if matched_row != -1:
            self.diag_table.selectRow(matched_row)
            item = self.diag_table.item(matched_row, 0)
            if item:
                self.diag_table.scrollToItem(item)
