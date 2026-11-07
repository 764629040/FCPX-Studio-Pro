"""
PyQt6 并排双视图画布与限定画板组件 (Side-by-Side Dual Canvas & Bounded Artboard)
核心功能：
1. 左右并排双视界对照：
   - 左视图 (PSD 原稿预览): 显示 PSD 原始渲染画面或当前选中图层的原始复合切片。
   - 右视图 (应用内转换结果预览): 真实呈现矢量文字排版、字体字号坐标与 32 位透明 RGBA 贴图还原。
2. 同步缩放与平移联动：左右视图的鼠标滚轮缩放、中键拖拽/平移完全锁定同步。
3. 视图模式切换：支持“整体画布对照 (Full Canvas)”与“当前选中图层对照 (Selected Layer)”。
4. 经典 16×16px 棋盘格暗色透明背景网格，支持一键开关与 QSettings 状态持久化记忆。
5. 字体缺失与缺字状态徽章 (complete 🟢 / partial_missing 🟠 / font_missing 🔴 / unverifiable 🟡)，
   点击徽章可直接联动定位至转换诊断报告。
6. 降级图层并排对照与空图层/图层组“无像素内容”清晰占位提示，严禁空白图伪装。
7. 画布顶部居中常驻显式红线警示：'⚠️ 应用内预览，非 FCPX 最终渲染'。
"""
import os
from typing import Optional, Dict, Any, List
from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QComboBox, 
    QSpinBox, QPushButton, QGraphicsView, QGraphicsScene, 
    QGraphicsItem, QGraphicsRectItem, QSplitter, QFrame
)
from PyQt6.QtCore import Qt, QRectF, QPointF, pyqtSignal, QSettings
from PyQt6.QtGui import QColor, QPen, QBrush, QFont, QPainter, QCursor, QPixmap, QIcon

PRESET_RESOLUTIONS = {
    "1080P 全高清 (1920 × 1080)": (1920, 1080),
    "4K 超高清 (3840 × 2160)": (3840, 2160),
    "2K 超清 (2560 × 1440)": (2560, 1440),
    "720P 高清 (1280 × 720)": (1280, 720),
    "竖版 1080P 抖音/短视频 (1080 × 1920)": (1080, 1920),
    "竖版 4K 短视频 (2160 × 3840)": (2160, 3840),
    "方形 1:1 视频 (1080 × 1080)": (1080, 1080),
    "自定义分辨率...": None
}


def create_checkerboard_brush(tile_size: int = 16, c1: QColor = QColor("#1C1D22"), c2: QColor = QColor("#252830")) -> QBrush:
    """生成 16x16px 暗色调棋盘格半透明纹理笔刷"""
    pm = QPixmap(tile_size * 2, tile_size * 2)
    p = QPainter(pm)
    p.fillRect(0, 0, tile_size, tile_size, c1)
    p.fillRect(tile_size, 0, tile_size, tile_size, c2)
    p.fillRect(0, tile_size, tile_size, tile_size, c2)
    p.fillRect(tile_size, tile_size, tile_size, tile_size, c1)
    p.end()
    return QBrush(pm)


def text_render_font_size(info) -> int:
    """
    文本图元绘制字号（唯一来源）。

    A-3 修复要点：
    旧实现绘制时用 `font_size / 2.2`（等于压缩到 0.4545），而建框/命中区域
    用未压缩的原字号，导致"字形远小于框体、点选区域与可见文字错位"。

    现在绘制与建框共用本函数，缩放只由画布缩放因子承担，
    不再有 `/2.2` 这类无依据的魔数。
    """
    fsize = float(getattr(info, "font_size", 0.0) or 0.0)
    # PSD 字号是像素单位；Qt 的 QFont 以 point 计，1pt ≈ 1.333px。
    # 这里把像素字号换算为等价 point 值，使字形实际像素高度贴近 bbox 高度。
    pt = fsize * 0.75
    # 下限 1 而非 8：字号 8 会把小字号图层强行放大，破坏与 bbox 的比例关系。
    return max(1, int(round(pt)))


class ConvertedLayerGraphicItem(QGraphicsRectItem):
    """
    右侧：应用内转换结果图元 (矢量文字 / 32位透明 RGBA 贴图)
    集成字体四态徽章、缺字标记、降级徽章与拖拽交互
    """
    def __init__(self, layer_info, on_moved_callback=None, on_badge_clicked=None):
        super().__init__()
        self.layer_info = layer_info
        self.on_moved_callback = on_moved_callback
        self.on_badge_clicked = on_badge_clicked
        self.is_highlighted = False

        self.pixmap: Optional[QPixmap] = None
        self._init_pixmap()

        self.setFlags(
            QGraphicsItem.GraphicsItemFlag.ItemIsMovable |
            QGraphicsItem.GraphicsItemFlag.ItemIsSelectable |
            QGraphicsItem.GraphicsItemFlag.ItemSendsGeometryChanges
        )
        self.update_geometry_from_info()

    def _init_pixmap(self):
        # 若为降级贴图，载入 32 位透明 RGBA PNG
        png_p = getattr(self.layer_info, "fallback_png_path", None)
        if png_p and os.path.exists(png_p):
            self.pixmap = QPixmap(png_p)
        elif getattr(self.layer_info, "original_slice_bytes", None):
            pm = QPixmap()
            if pm.loadFromData(self.layer_info.original_slice_bytes):
                self.pixmap = pm

    def update_geometry_from_info(self):
        info = self.layer_info
        mx, my = info.motion_pos
        self.setPos(mx, -my)

        if info.kind == "type":
            # 建框尺寸直接采用 PSD 原稿 bbox，与字形绘制共用同一坐标来源。
            # 禁用"按字符数 × 原字号"反推：该算法在竖排、中文、窄字距场景下
            # 会把框体撑到远超真实 bbox（实测 Text01 框宽 1080px vs bbox 宽 31px）。
            bbox = getattr(info, "psd_bbox", None)
            if bbox:
                left, top, right, bottom = bbox
                w = max(20.0, float(right - left))
                h = max(20.0, float(bottom - top))
            else:
                lines = info.text.split("\n")
                line_count = max(1, len(lines))
                max_line_len = max(len(l) for l in lines) if lines else 1
                # 无 bbox 时的兜底：用与绘制一致的字号换算
                fs = text_render_font_size(info)
                w = max(40.0, max_line_len * fs * 0.6)
                h = max(40.0, line_count * fs * 1.3)
            self.setRect(-w/2.0, -h/2.0, w, h)
        else:
            # 降级贴图图层：基于包围盒或像素图尺寸
            if self.pixmap and not self.pixmap.isNull():
                w = self.pixmap.width()
                h = self.pixmap.height()
            elif info.psd_bbox:
                l, t, r, b = info.psd_bbox
                w = max(10, r - l)
                h = max(10, b - t)
            else:
                w, h = 100, 100
            self.setRect(-w/2.0, -h/2.0, w, h)

        # ── 旋转还原 ──
        # 竖排/旋转文本在 PSD 中以仿射矩阵表达，解析层已还原为 rotation 角度；
        # 此处必须真正把角度应用到图元，否则 90° 竖排会被画成横排并越出画板。
        # 同时按原稿 bbox 校正矩形：旋转后以 bbox 真实宽高为准，避免
        # "用文本长度反推宽高"在竖排场景下失真。
        rotation = float(getattr(info, "rotation", 0.0) or 0.0)
        if rotation:
            bbox = getattr(info, "psd_bbox", None)
            if bbox:
                left, top, right, bottom = bbox
                bw = max(10.0, float(right - left))
                bh = max(10.0, float(bottom - top))
                # 图元以中心为原点；90°/270° 时 bbox 的长边是视觉高度、
                # 短边是视觉宽度，旋转后外接框正好对应 (bw, bh)。
                if rotation % 180 == 90:
                    self.setRect(-bh / 2.0, -bw / 2.0, bh, bw)
                else:
                    self.setRect(-bw / 2.0, -bh / 2.0, bw, bh)
            self.setTransformOriginPoint(0.0, 0.0)
            self.setRotation(rotation)
        else:
            self.setRotation(0.0)

        self.setVisible(info.visible)
        self.update()

    def get_badge_info(self):
        """返回当前图层的徽章文本、背景色与前景色 (badge_text, bg_col, fg_col)"""
        info = self.layer_info
        if info.kind == "type":
            font_info = getattr(info, "font_info", {}) or {}
            cov = font_info.get("glyph_coverage")
            has_risk = font_info.get("has_missing_glyphs", False)
            missing = font_info.get("missing_chars", [])
            det_status = font_info.get("detection_status", "detected")

            if det_status == "font_missing":
                badge_text = f"🔴 原始字体未安装 (回退: {font_info.get('fallback_font', 'PingFang')})"
                bg_col, fg_col = QColor("#3D1418"), QColor("#FF453A")
            elif has_risk and missing:
                miss_str = ", ".join(missing[:3]) + ("..." if len(missing) > 3 else "")
                badge_text = f"🟠 缺字: {miss_str}"
                bg_col, fg_col = QColor("#3D2914"), QColor("#FF9F0A")
            elif cov is None:
                badge_text = "🟡 无法验证字形"
                bg_col, fg_col = QColor("#3D3514"), QColor("#FFD60A")
            else:
                badge_text = "🟢 字体 100% 支持"
                bg_col, fg_col = QColor("#14301C"), QColor("#30D158")
            return badge_text, bg_col, fg_col
        else:
            return "🟠 [降级为 32位贴图]", QColor("#3D2914"), QColor("#FF9F0A")

    def paint(self, painter: QPainter, option, widget=None):
        info = self.layer_info
        if not info.visible:
            return

        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setRenderHint(QPainter.RenderHint.TextAntialiasing)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)

        rect = self.rect()

        # 1. 选中或联动高亮状态
        if self.isSelected() or self.is_highlighted:
            pen = QPen(QColor("#0A84FF"), 2, Qt.PenStyle.DashLine)
            painter.setPen(pen)
            painter.setBrush(QColor(10, 132, 255, 30))
            painter.drawRoundedRect(rect, 4, 4)
            # 锚点
            painter.setBrush(QColor("#FFFFFF"))
            painter.setPen(QColor("#0A84FF"))
            s = 6
            painter.drawRect(int(rect.left()-s/2), int(rect.top()-s/2), s, s)
            painter.drawRect(int(rect.right()-s/2), int(rect.top()-s/2), s, s)
            painter.drawRect(int(rect.left()-s/2), int(rect.bottom()-s/2), s, s)
            painter.drawRect(int(rect.right()-s/2), int(rect.bottom()-s/2), s, s)
        else:
            painter.setPen(QPen(QColor(255, 255, 255, 25), 1))
            painter.setBrush(QColor(0, 0, 0, 0))
            painter.drawRoundedRect(rect, 4, 4)

        # 2. 内容渲染
        if info.kind == "type":
            # 矢量文字渲染
            #
            painter.setPen(QColor("#FFFFFF"))
            font_size = text_render_font_size(info)
            font = QFont(info.font_name or "PingFang SC", font_size)
            painter.setFont(font)
            painter.drawText(rect, Qt.AlignmentFlag.AlignCenter, info.text)

            # 3. 字体四态徽章与缺字标记绘制 (位于包围盒上方)
            badge_text, bg_col, fg_col = self.get_badge_info()

            # 绘制徽章胶囊
            b_font = QFont("PingFang SC", 9, QFont.Weight.Bold)
            painter.setFont(b_font)
            b_w = max(110.0, len(badge_text) * 7.5 + 14)
            b_h = 18.0
            b_rect = QRectF(rect.left(), rect.top() - b_h - 4, b_w, b_h)

            painter.setPen(QPen(fg_col, 1))
            painter.setBrush(QBrush(bg_col))
            painter.drawRoundedRect(b_rect, 4, 4)
            painter.setPen(fg_col)
            painter.drawText(b_rect, Qt.AlignmentFlag.AlignCenter, badge_text)

        else:
            # 降级贴图图层：绘制 32-bit 透明 PNG 像素
            if self.pixmap and not self.pixmap.isNull():
                painter.drawPixmap(rect.toRect(), self.pixmap)

            # 降级徽标
            b_text, bg_col, fg_col = self.get_badge_info()
            b_font = QFont("PingFang SC", 9, QFont.Weight.Bold)
            painter.setFont(b_font)
            b_w = 135.0
            b_h = 18.0
            b_rect = QRectF(rect.left(), rect.top() - b_h - 4, b_w, b_h)

            painter.setPen(QPen(fg_col, 1))
            painter.setBrush(QBrush(bg_col))
            painter.drawRoundedRect(b_rect, 4, 4)
            painter.setPen(fg_col)
            painter.drawText(b_rect, Qt.AlignmentFlag.AlignCenter, b_text)

        painter.restore()

    def mousePressEvent(self, event):
        super().mousePressEvent(event)
        # 点击顶部徽章区域时发射跳转诊断信号
        pos = event.pos()
        rect = self.rect()
        if pos.y() < rect.top() and (rect.top() - 25) <= pos.y():
            if self.on_badge_clicked:
                self.on_badge_clicked(self.layer_info)

    def itemChange(self, change, value):
        if change == QGraphicsItem.GraphicsItemChange.ItemPositionChange and self.scene():
            new_pos = value
            motion_x = round(new_pos.x(), 2)
            motion_y = round(-new_pos.y(), 2)
            self.layer_info.motion_pos = (motion_x, motion_y)

            if self.on_moved_callback:
                self.on_moved_callback(self.layer_info)

        return super().itemChange(change, value)


class OriginalLayerGraphicItem(QGraphicsRectItem):
    """
    左侧：PSD 原稿预览图元 (原始 PSD 复合切片 / 整体原稿)
    """
    def __init__(self, layer_info, artboard_w: int, artboard_h: int):
        super().__init__()
        self.layer_info = layer_info
        self.artboard_w = artboard_w
        self.artboard_h = artboard_h
        self.is_highlighted = False
        self.is_empty_or_group = False

        self.pixmap: Optional[QPixmap] = None
        self._init_pixmap()
        self.update_geometry()

    def _init_pixmap(self):
        slice_bytes = getattr(self.layer_info, "original_slice_bytes", None)
        self.placeholder_reason = None   # None 表示有真实像素可渲染

        l_type = getattr(self.layer_info, "layer_type", self.layer_info.kind)
        is_empty = getattr(self.layer_info, "is_empty", False)

        # 先按图层语义判定，再看像素，保证三类原因互不混淆
        if l_type == "group":
            self.placeholder_reason = "group"
            self.is_empty_or_group = True
            return

        if is_empty:
            self.placeholder_reason = "empty_layer"
            self.is_empty_or_group = True
            return

        if not slice_bytes:
            # 解析结果里根本没有切片（如未开启 extract_thumbnails）
            self.placeholder_reason = "no_slice"
            self.is_empty_or_group = True
            return

        pm = QPixmap()
        if not pm.loadFromData(slice_bytes):
            # 有字节但解码失败：数据损坏，不是"空图层"
            self.placeholder_reason = "decode_failed"
            self.is_empty_or_group = True
            return

        self.pixmap = pm
        if self.pixmap.isNull():
            self.placeholder_reason = "decode_failed"
            self.is_empty_or_group = True
            return

        self.is_empty_or_group = False

    def update_geometry(self):
        bbox = self.layer_info.psd_bbox
        if bbox:
            l, t, r, b = bbox
            cx = (l + r) / 2.0
            cy = (t + b) / 2.0
            w = max(10, r - l)
            h = max(10, b - t)
            # 换算至画板中心 (0, 0)
            center_x = self.artboard_w / 2.0
            center_y = self.artboard_h / 2.0
            qt_x = cx - center_x
            qt_y = cy - center_y
            self.setPos(qt_x, qt_y)
            self.setRect(-w/2.0, -h/2.0, w, h)
        else:
            mx, my = self.layer_info.motion_pos
            self.setPos(mx, -my)
            self.setRect(-60, -25, 120, 50)

        self.setVisible(self.layer_info.visible)
        self.update()

    def paint(self, painter: QPainter, option, widget=None):
        if not self.layer_info.visible:
            return

        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)

        rect = self.rect()

        # 选中高亮
        if self.is_highlighted:
            pen = QPen(QColor("#30D158"), 2, Qt.PenStyle.DashLine)
            painter.setPen(pen)
            painter.setBrush(QColor(48, 209, 88, 25))
            painter.drawRoundedRect(rect, 4, 4)
        else:
            painter.setPen(QPen(QColor(255, 255, 255, 15), 1))
            painter.setBrush(QColor(0, 0, 0, 0))
            painter.drawRoundedRect(rect, 4, 4)

        if self.pixmap and not self.pixmap.isNull():
            painter.drawPixmap(rect.toRect(), self.pixmap)
        elif self.is_empty_or_group:
            # 明确展示占位说明，绝不空白假冒。
            # A-9：图层组 / 真空层 / 切片解码失败 是三种不同原因，
            # 必须给出可区分的文案，不能一律写成"空图层 / 无像素内容"。
            painter.setPen(QColor("#8E8E93"))
            painter.setBrush(QColor(40, 42, 50, 180))
            painter.drawRoundedRect(rect, 4, 4)
            painter.setPen(QColor("#D1D1D6"))
            font = QFont("PingFang SC", 9)
            painter.setFont(font)
            placeholder_msgs = {
                "group": "📁 图层组容器 / 无独立像素",
                "empty_layer": "⚠️ 真空图层 / 尺寸为零或无有效像素",
                "no_slice": "🖼 未生成原稿切片 / 请开启 extract_thumbnails",
                "decode_failed": "❌ 原稿切片解码失败 / 数据可能损坏",
            }
            msg = placeholder_msgs.get(
                getattr(self, "placeholder_reason", None),
                "⚠️ 无像素内容",
            )
            painter.drawText(rect, Qt.AlignmentFlag.AlignCenter, msg)

        painter.restore()


class InfiniteCanvasView(QGraphicsView):
    """单侧无限平移与缩放画板视图 (支持棋盘格背景与同步联动)"""
    zoom_sync_signal = pyqtSignal(object)  # 发射 Transform 对象
    pan_sync_signal = pyqtSignal(int, int) # 发射 ScrollBar (h, v)
    layer_moved_signal = pyqtSignal(object)
    badge_clicked_signal = pyqtSignal(object)

    def __init__(self, title: str, is_original: bool = False, parent=None):
        super().__init__(parent)
        self.view_title = title
        self.is_original = is_original
        self.scene = QGraphicsScene(-50000, -50000, 100000, 100000)
        self.setScene(self.scene)

        self.artboard_w = 1920
        self.artboard_h = 1080
        self.artboard_item: Optional[QGraphicsRectItem] = None
        self.items_map: Dict[int, Any] = {}
        self.checkerboard_enabled = True
        self.view_mode = "all"  # "all" 整体画布对照, "layer" 当前选中图层对照
        self.current_selected_index: Optional[int] = None
        self._is_syncing = False

        self.checker_brush = create_checkerboard_brush(16)

        # 视口基础配置
        self.setRenderHint(QPainter.RenderHint.Antialiasing)
        self.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.setResizeAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setDragMode(QGraphicsView.DragMode.NoDrag)
        self.setBackgroundBrush(QBrush(QColor("#0E0F12")))

        self._is_panning = False
        self._pan_start_x = 0
        self._pan_start_y = 0

        self._rebuild_artboard()

    def set_checkerboard_enabled(self, enabled: bool):
        """开启或关闭透明棋盘格背景"""
        self.checkerboard_enabled = enabled
        if self.artboard_item:
            if enabled:
                self.artboard_item.setBrush(self.checker_brush)
            else:
                self.artboard_item.setBrush(QBrush(QColor("#14161C")))
        self.scene.update()

    def _rebuild_artboard(self):
        """重绘画板限定区域、棋盘格背景与安全框"""
        if self.artboard_item:
            self.scene.removeItem(self.artboard_item)
            self.artboard_item = None

        w, h = self.artboard_w, self.artboard_h
        rect = QRectF(-w/2.0, -h/2.0, w, h)

        self.artboard_item = QGraphicsRectItem(rect)
        if self.checkerboard_enabled:
            self.artboard_item.setBrush(self.checker_brush)
        else:
            self.artboard_item.setBrush(QBrush(QColor("#14161C")))

        border_col = QColor("#30D158") if self.is_original else QColor("#0A84FF")
        self.artboard_item.setPen(QPen(border_col, 2))
        self.artboard_item.setZValue(-100)
        self.scene.addItem(self.artboard_item)

        # 清理旧的辅助线
        for item in self.scene.items():
            if item != self.artboard_item and item not in self.items_map.values():
                self.scene.removeItem(item)

        # 90% 动作安全框
        w90, h90 = w * 0.9, h * 0.9
        safe90 = self.scene.addRect(-w90/2, -h90/2, w90, h90, QPen(QColor(255, 255, 255, 20), 1, Qt.PenStyle.DashLine))
        safe90.setZValue(-90)

        # 80% 标题安全框
        w80, h80 = w * 0.8, h * 0.8
        safe80 = self.scene.addRect(-w80/2, -h80/2, w80, h80, QPen(QColor(10, 132, 255, 30), 1, Qt.PenStyle.DashLine))
        safe80.setZValue(-90)

        # 十字准星
        cross_pen = QPen(QColor(255, 255, 255, 30), 1)
        lv = self.scene.addLine(0, -h/2, 0, h/2, cross_pen)
        lh = self.scene.addLine(-w/2, 0, w/2, 0, cross_pen)
        lv.setZValue(-90)
        lh.setZValue(-90)

    def set_artboard_resolution(self, width: int, height: int):
        self.artboard_w = width
        self.artboard_h = height
        self._rebuild_artboard()
        # A-13 修复：画板尺寸是图元定位的参照系（pos = bbox中心 - 画板中心）。
        # 旧实现只重建画板框，不重算既有图元，导致"先加载图层、后改分辨率"
        # 时整幅错位（竖版实测偏差约 200px）。
        # 这里对所有既有图元按新参照系重新定位。
        self._relayout_items()
        self.fit_artboard_in_view()

    def _relayout_items(self):
        """按当前画板尺寸重新计算所有既有图元的位置与尺寸"""
        for item in getattr(self, "items_map", {}).values():
            if hasattr(item, "artboard_w"):
                item.artboard_w = self.artboard_w
            if hasattr(item, "artboard_h"):
                item.artboard_h = self.artboard_h
            # 左栏用 update_geometry()，右栏用 update_geometry_from_info()
            if hasattr(item, "update_geometry_from_info"):
                item.update_geometry_from_info()
            elif hasattr(item, "update_geometry"):
                item.update_geometry()

    def fit_artboard_in_view(self):
        margin = 80
        target_rect = QRectF(
            -self.artboard_w/2.0 - margin, 
            -self.artboard_h/2.0 - margin, 
            self.artboard_w + margin*2, 
            self.artboard_h + margin*2
        )
        self.fitInView(target_rect, Qt.AspectRatioMode.KeepAspectRatio)
        if not self._is_syncing:
            self.zoom_sync_signal.emit(self.transform())

    def reset_100_percent(self):
        self.resetTransform()
        self.centerOn(0, 0)
        if not self._is_syncing:
            self.zoom_sync_signal.emit(self.transform())

    def sync_transform_from_peer(self, transform):
        """同步来自对侧画板的缩放矩阵"""
        if self._is_syncing:
            return
        self._is_syncing = True
        self.setTransform(transform)
        self._is_syncing = False

    def sync_scroll_from_peer(self, h_val: int, v_val: int):
        """同步来自对侧画板的滚动条位置"""
        if self._is_syncing:
            return
        self._is_syncing = True
        self.horizontalScrollBar().setValue(h_val)
        self.verticalScrollBar().setValue(v_val)
        self._is_syncing = False

    def load_layers(self, layers):
        for item in self.items_map.values():
            self.scene.removeItem(item)
        self.items_map.clear()

        for info in layers:
            if self.is_original:
                item = OriginalLayerGraphicItem(info, self.artboard_w, self.artboard_h)
            else:
                item = ConvertedLayerGraphicItem(
                    info, 
                    on_moved_callback=self.layer_moved_signal.emit,
                    on_badge_clicked=self.badge_clicked_signal.emit
                )
            self.scene.addItem(item)
            self.items_map[info.index] = item

        self._apply_view_mode_filter()

    def set_view_mode(self, mode: str):
        """切换视图模式：'all' 整体对照 / 'layer' 当前图层对照"""
        self.view_mode = mode
        self._apply_view_mode_filter()

    def _apply_view_mode_filter(self):
        if self.view_mode == "all":
            for item in self.items_map.values():
                item.setVisible(item.layer_info.visible)
        else:
            # 仅显示当前选中的图层
            for idx, item in self.items_map.items():
                is_target = (idx == self.current_selected_index)
                item.setVisible(is_target)

    def highlight_layer(self, layer_index: int):
        """高亮并选中指定图层"""
        self.current_selected_index = layer_index
        for idx, item in self.items_map.items():
            if idx == layer_index:
                item.setSelected(True)
                item.is_highlighted = True
            else:
                item.setSelected(False)
                item.is_highlighted = False
            item.update()

        if self.view_mode == "layer":
            self._apply_view_mode_filter()

    def update_layer_display(self, info):
        if info.index in self.items_map:
            item = self.items_map[info.index]
            if hasattr(item, "update_geometry_from_info"):
                item.update_geometry_from_info()
            elif hasattr(item, "update_geometry"):
                item.update_geometry()
            self.scene.update()

    # ====== 鼠标平移与滚轮缩放事件 ======
    def wheelEvent(self, event):
        zoom_in_factor = 1.15
        zoom_out_factor = 1.0 / zoom_in_factor
        zoom_factor = zoom_in_factor if event.angleDelta().y() > 0 else zoom_out_factor

        current_scale = self.transform().m11()
        new_scale = current_scale * zoom_factor
        if 0.08 <= new_scale <= 25.0:
            self.scale(zoom_factor, zoom_factor)
            if not self._is_syncing:
                self.zoom_sync_signal.emit(self.transform())
                self.pan_sync_signal.emit(self.horizontalScrollBar().value(), self.verticalScrollBar().value())

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.MiddleButton or (
            event.button() == Qt.MouseButton.LeftButton and event.modifiers() == Qt.KeyboardModifier.ShiftModifier
        ):
            self._is_panning = True
            self._pan_start_x = event.pos().x()
            self._pan_start_y = event.pos().y()
            self.setCursor(QCursor(Qt.CursorShape.ClosedHandCursor))
            event.accept()
            return
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self._is_panning:
            dx = event.pos().x() - self._pan_start_x
            dy = event.pos().y() - self._pan_start_y
            self._pan_start_x = event.pos().x()
            self._pan_start_y = event.pos().y()
            self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() - dx)
            self.verticalScrollBar().setValue(self.verticalScrollBar().value() - dy)

            if not self._is_syncing:
                self.pan_sync_signal.emit(self.horizontalScrollBar().value(), self.verticalScrollBar().value())

            event.accept()
            return
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        if self._is_panning:
            self._is_panning = False
            self.setCursor(QCursor(Qt.CursorShape.ArrowCursor))
            event.accept()
            return
        super().mouseReleaseEvent(event)

    def drawForeground(self, painter: QPainter, rect: QRectF):
        """视图左上角绘制标题徽章标识"""
        super().drawForeground(painter, rect)
        painter.save()
        painter.resetTransform()

        tag_rect = QRectF(12, 12, 170, 24)
        bg = QColor("#14301C") if self.is_original else QColor("#162338")
        fg = QColor("#30D158") if self.is_original else QColor("#0A84FF")
        border = fg

        painter.setPen(QPen(border, 1))
        painter.setBrush(QBrush(bg))
        painter.drawRoundedRect(tag_rect, 4, 4)

        painter.setPen(fg)
        painter.setFont(QFont("PingFang SC", 10, QFont.Weight.Bold))
        painter.drawText(tag_rect, Qt.AlignmentFlag.AlignCenter, self.view_title)

        painter.restore()

    def drawBackground(self, painter: QPainter, rect: QRectF):
        """绘制无限暗色网格点阵底板"""
        super().drawBackground(painter, rect)
        painter.save()
        painter.setPen(QColor(255, 255, 255, 12))
        grid_size = 40
        left = int(rect.left()) - (int(rect.left()) % grid_size)
        top = int(rect.top()) - (int(rect.top()) % grid_size)
        points = []
        for x in range(left, int(rect.right()), grid_size):
            for y in range(top, int(rect.bottom()), grid_size):
                points.append(QPointF(x, y))
        painter.drawPoints(points)
        painter.restore()


class CanvasContainer(QWidget):
    """
    整合并排双画布、同步控制器与红线免责警示标签的完整交互容器
    """
    layer_moved_signal = pyqtSignal(object)
    badge_clicked_signal = pyqtSignal(object)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.settings = QSettings("FCPXStudioPro", "FCPXStudioPro")
        self._init_ui()

    def _init_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        # 1. 顶部综合控制栏
        top_bar = QWidget()
        top_bar.setStyleSheet("background-color: #16171B; border-bottom: 1px solid #2B2D35;")
        bar_layout = QHBoxLayout(top_bar)
        bar_layout.setContentsMargins(10, 6, 10, 6)
        bar_layout.setSpacing(8)

        # 分辨率预设下拉
        bar_layout.addWidget(QLabel("限定画板:"))
        self.preset_combo = QComboBox()
        self.preset_combo.addItems(list(PRESET_RESOLUTIONS.keys()))
        self.preset_combo.setStyleSheet("background-color: #1F2128; color: #FFF; padding: 4px; border: 1px solid #333; border-radius: 4px; font-size: 11px;")
        self.preset_combo.currentIndexChanged.connect(self._on_preset_changed)
        bar_layout.addWidget(self.preset_combo)

        # 宽高输入
        bar_layout.addWidget(QLabel("W:"))
        self.spin_w = QSpinBox()
        self.spin_w.setRange(200, 16000)
        self.spin_w.setValue(1920)
        self.spin_w.setStyleSheet("background-color: #1F2128; color: #FFF; border: 1px solid #333; font-size: 11px;")
        self.spin_w.valueChanged.connect(self._on_custom_size_changed)
        bar_layout.addWidget(self.spin_w)

        bar_layout.addWidget(QLabel("H:"))
        self.spin_h = QSpinBox()
        self.spin_h.setRange(200, 16000)
        self.spin_h.setValue(1080)
        self.spin_h.setStyleSheet("background-color: #1F2128; color: #FFF; border: 1px solid #333; font-size: 11px;")
        self.spin_h.valueChanged.connect(self._on_custom_size_changed)
        bar_layout.addWidget(self.spin_h)

        # 横竖版切换
        self.orient_btn = QPushButton("🔄 横版 (16:9)")
        self.orient_btn.setStyleSheet("background-color: #242732; color: #0A84FF; font-weight: bold; padding: 4px 8px; border-radius: 4px; font-size: 11px;")
        self.orient_btn.clicked.connect(self._on_toggle_orientation)
        bar_layout.addWidget(self.orient_btn)

        # 对照模式切换
        bar_layout.addWidget(QLabel("模式:"))
        self.mode_combo = QComboBox()
        self.mode_combo.addItems(["🔍 整体画布对照", "🎯 当前选中图层对照"])
        self.mode_combo.setStyleSheet("background-color: #1F2128; color: #30D158; font-weight: bold; padding: 4px; border: 1px solid #333; border-radius: 4px; font-size: 11px;")
        self.mode_combo.currentIndexChanged.connect(self._on_mode_changed)
        bar_layout.addWidget(self.mode_combo)

        # 棋盘格开关
        saved_checker = self.settings.value("checkerboard_enabled", True, type=bool)
        self.checker_btn = QPushButton("🏁 棋盘格背景")
        self.checker_btn.setCheckable(True)
        self.checker_btn.setChecked(saved_checker)
        self.checker_btn.setStyleSheet("""
            QPushButton {
                background-color: #242732;
                color: #A0A4B0;
                padding: 4px 8px;
                border-radius: 4px;
                font-size: 11px;
            }
            QPushButton:checked {
                background-color: #0A84FF;
                color: #FFFFFF;
                font-weight: bold;
            }
        """)
        self.checker_btn.toggled.connect(self._on_checkerboard_toggled)
        bar_layout.addWidget(self.checker_btn)

        bar_layout.addStretch()

        # 缩放控制
        self.zoom_label = QLabel("100%")
        self.zoom_label.setStyleSheet("color: #A0A4B0; font-family: monospace; font-size: 11px;")
        bar_layout.addWidget(self.zoom_label)

        self.fit_btn = QPushButton("⊡ 适中显示 (Fit)")
        self.fit_btn.setStyleSheet("background-color: #242732; color: #E0E2E8; padding: 4px 8px; border-radius: 4px; font-size: 11px;")
        self.fit_btn.clicked.connect(self._on_fit_clicked)
        bar_layout.addWidget(self.fit_btn)

        self.reset_btn = QPushButton("1:1")
        self.reset_btn.setStyleSheet("background-color: #242732; color: #E0E2E8; padding: 4px 8px; border-radius: 4px; font-size: 11px;")
        self.reset_btn.clicked.connect(self._on_reset_100_clicked)
        bar_layout.addWidget(self.reset_btn)

        main_layout.addWidget(top_bar)

        # 2. 居中显式红线警示条 (杜绝误导)
        disclaimer_bar = QFrame()
        disclaimer_bar.setStyleSheet("""
            QFrame {
                background-color: #261E0A;
                border-bottom: 1px solid #FF9F0A;
                padding: 3px;
            }
        """)
        disc_l = QHBoxLayout(disclaimer_bar)
        disc_l.setContentsMargins(4, 2, 4, 2)
        lbl_disc = QLabel("⚠️ 应用内预览，非 FCPX 最终渲染 (Final Cut Pro 检查器保留全发布控制)")
        lbl_disc.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_disc.setStyleSheet("color: #FFD60A; font-weight: bold; font-size: 12px;")
        disc_l.addWidget(lbl_disc)
        main_layout.addWidget(disclaimer_bar)

        # 3. 并排左右双视界 Splitter 容器
        self.splitter = QSplitter(Qt.Orientation.Horizontal)
        self.splitter.setStyleSheet("""
            QSplitter::handle {
                background-color: #2B2D35;
                width: 3px;
            }
            QSplitter::handle:hover {
                background-color: #0A84FF;
            }
        """)

        # 左视图：PSD 原稿
        self.left_canvas = InfiniteCanvasView("PSD 原稿预览", is_original=True)
        self.left_canvas.set_checkerboard_enabled(saved_checker)

        # 右视图：应用内转换结果
        self.right_canvas = InfiniteCanvasView("应用内转换结果预览", is_original=False)
        self.right_canvas.set_checkerboard_enabled(saved_checker)
        self.right_canvas.layer_moved_signal.connect(self.layer_moved_signal.emit)
        self.right_canvas.badge_clicked_signal.connect(self.badge_clicked_signal.emit)

        # 双向同步绑定
        self.left_canvas.zoom_sync_signal.connect(self.right_canvas.sync_transform_from_peer)
        self.right_canvas.zoom_sync_signal.connect(self.left_canvas.sync_transform_from_peer)

        self.left_canvas.pan_sync_signal.connect(self.right_canvas.sync_scroll_from_peer)
        self.right_canvas.pan_sync_signal.connect(self.left_canvas.sync_scroll_from_peer)

        # 缩放指示刷新
        self.left_canvas.zoom_sync_signal.connect(self._on_zoom_updated)
        self.right_canvas.zoom_sync_signal.connect(self._on_zoom_updated)

        self.splitter.addWidget(self.left_canvas)
        self.splitter.addWidget(self.right_canvas)
        self.splitter.setSizes([600, 600])

        main_layout.addWidget(self.splitter, stretch=1)

    def _on_checkerboard_toggled(self, checked: bool):
        self.settings.setValue("checkerboard_enabled", checked)
        self.left_canvas.set_checkerboard_enabled(checked)
        self.right_canvas.set_checkerboard_enabled(checked)

    def _on_mode_changed(self, idx: int):
        mode = "all" if idx == 0 else "layer"
        self.left_canvas.set_view_mode(mode)
        self.right_canvas.set_view_mode(mode)

    @staticmethod
    def _aspect_suffix(w: int, h: int) -> str:
        """
        由真实宽高推导画幅后缀，供方向按钮统一使用。

        A-17 修复要点：方向切换路径过去只写 "🔄 横版"/"🔄 竖版"，
        丢了 (16:9)/(9:16) 后缀，与预设路径文案不一致。
        现在两条路径都调用本函数，同一控件在任意路径下文案一致。
        """
        if w <= 0 or h <= 0:
            return ""
        from math import gcd
        g = gcd(int(w), int(h)) or 1
        return f"({int(w)//g}:{int(h)//g})"

    def _orientation_button_text(self, w: int, h: int) -> str:
        """方向按钮完整文案：方向 + 真实画幅比例"""
        if h > w:
            label = "竖版"
        elif w > h:
            label = "横版"
        else:
            label = "方形"
        suffix = self._aspect_suffix(w, h)
        return f"🔄 {label} {suffix}".strip()

    def _sync_preset_combo(self, w: int, h: int):
        """
        把预设下拉框同步到与当前真实宽高匹配的选项。

        A-12 修复要点：过去方向切换/手动改尺寸都不会反向同步下拉框，
        导致下拉框仍显示旧标签（如"竖版 1080×1920"）而画板已是 1920×1080。
        现在只要尺寸发生变化就重新对齐下拉框；无精确匹配则落到"自定义分辨率..."。
        """
        target_index = None
        custom_index = None
        for i in range(self.preset_combo.count()):
            text = self.preset_combo.itemText(i)
            preset = PRESET_RESOLUTIONS.get(text)
            if preset is None:
                custom_index = i
                continue
            if preset == (w, h) and target_index is None:
                target_index = i

        if target_index is None:
            target_index = custom_index
        if target_index is None or target_index == self.preset_combo.currentIndex():
            return

        self.preset_combo.blockSignals(True)
        self.preset_combo.setCurrentIndex(target_index)
        self.preset_combo.blockSignals(False)

    def _apply_resolution(self, w: int, h: int, sync_preset: bool = True):
        """
        唯一尺寸入口：输入框、方向按钮、预设下拉、左右画板同步更新。

        A-12 / A-17 共同根因是"多条路径各自更新一部分控件"，本函数收口后，
        任何入口（预设选择、手动输入、方向切换、外部调用）都走同一条同步逻辑。
        """
        # 1. 输入框（阻断信号，避免再次触发 _on_custom_size_changed 造成递归）
        for spin, val in ((self.spin_w, w), (self.spin_h, h)):
            spin.blockSignals(True)
            spin.setValue(val)
            spin.blockSignals(False)

        # 2. 方向按钮（统一带画幅后缀）
        self.orient_btn.setText(self._orientation_button_text(w, h))

        # 3. 预设下拉反向同步
        if sync_preset:
            self._sync_preset_combo(w, h)

        # 4. 两侧画板
        self.left_canvas.set_artboard_resolution(w, h)
        self.right_canvas.set_artboard_resolution(w, h)

    def _on_preset_changed(self, idx: int):
        name = self.preset_combo.currentText()
        res = PRESET_RESOLUTIONS.get(name)
        if res:
            w, h = res
            # 预设已是权威来源，无需反向同步下拉框
            self._apply_resolution(w, h, sync_preset=False)

    def _on_custom_size_changed(self):
        w = self.spin_w.value()
        h = self.spin_h.value()
        # 手动改尺寸后，下拉框必须回到匹配项或"自定义"，不得停留在旧预设标签
        self._apply_resolution(w, h, sync_preset=True)

    def _on_toggle_orientation(self):
        w = self.spin_w.value()
        h = self.spin_h.value()
        # 交换宽高后走统一入口，下拉框与按钮文案一并校正
        self._apply_resolution(h, w, sync_preset=True)

    def _on_fit_clicked(self):
        self.left_canvas.fit_artboard_in_view()
        self.right_canvas.fit_artboard_in_view()

    def _on_reset_100_clicked(self):
        self.left_canvas.reset_100_percent()
        self.right_canvas.reset_100_percent()

    def _on_zoom_updated(self, transform):
        pct = int(transform.m11() * 100)
        self.zoom_label.setText(f"{pct}%")

    def load_layers(self, layers):
        """载入图层并同时填充左右两侧画板"""
        self.left_canvas.load_layers(layers)
        self.right_canvas.load_layers(layers)
        self.left_canvas.fit_artboard_in_view()
        self.right_canvas.fit_artboard_in_view()

    def select_layer(self, info):
        """联动选中左右两侧的对应图层"""
        if info:
            self.left_canvas.highlight_layer(info.index)
            self.right_canvas.highlight_layer(info.index)

    def set_artboard_resolution(self, width: int, height: int):
        # 外部调用同样走唯一入口，保证下拉框/按钮/画板一致，
        # 避免"程序内部设了竖版、下拉框仍显示横版"这类标签与真实状态脱节。
        self._apply_resolution(width, height, sync_preset=True)

    def update_layer_display(self, info):
        self.left_canvas.update_layer_display(info)
        self.right_canvas.update_layer_display(info)

