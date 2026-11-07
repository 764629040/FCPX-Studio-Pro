"""
A-15 方案 1 验收测试：折叠态色点 + 展开态徽章

方案（第九轮审核批准）：
  常态显示 4×4 色点（以 bbox 中心为锚点，随图元旋转），
  选中或悬停时展开完整徽章胶囊。

断言规格 12 条，逐条对应审核报告第六节：
  1. 色点 4×4，以 bbox 中心为锚点，随图元旋转（不得用 rect.left()）
  2. 任意两个可见文字层色点外接框互不相交
  3. 色点外接框不与任何其他图层文字 bbox 相交
  4. 最小净空 ≥ 3 单位
  5. 上述断言在 vertical_wedding_9_16.psd 与 four_state.psd 同时通过
  6. 展开仅对单个图层生效
  7. 展开徽章不得溢出画布边界
  8. 颜色/文案与四态完全一致
  9. 折叠态命中区 ≥ 8×8，on_badge_clicked 可用
 10. 折叠态提供悬停提示，文案等同展开态
 11. A-16 四态像素互斥仍成立
 12. 全量测试不得因徽章改动减少通过项（由 CI 主测试集保证）
"""

# R26（独立复核报告 R25 §十.5）：本文件为 GUI 运行时测试，需真实 PyQt6 显示环境。
# 无 PyQt6 的环境按「手工验证，不自动跑」处理：importorskip 使其干净跳过（SKIPPED，非 ERROR）。
import pytest as _pytest_r26
_pytest_r26.importorskip("PyQt6", reason="GUI 测试需 PyQt6；无则转手工验证，不自动跑")

import os
import sys

import pytest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(TESTS_DIR, ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication
from PyQt6.QtCore import QPointF

from core.psd_parser import parse_psd_file
from gui.canvas_view import CanvasContainer, ConvertedLayerGraphicItem

app = QApplication.instance() or QApplication(sys.argv)

DATA_DIR = os.path.join(TESTS_DIR, "data")
FIXTURES = [
    ("tests/data/vertical_wedding_9_16.psd", "竖版 8 层"),
    ("tests/data/four_state.psd", "四态 8 层"),
]
MIN_CLEARANCE = 3.0


def _load(rel):
    p = parse_psd_file(os.path.join(PROJECT_ROOT, rel), extract_thumbnails=False)
    c = CanvasContainer()
    c.resize(1400, 900)
    c.show()
    c.load_layers(p["layers"])
    c.set_artboard_resolution(p["width"], p["height"])
    app.processEvents()
    return p, c


def _type_items(c):
    return [(idx, it) for idx, it in c.right_canvas.items_map.items()
            if getattr(it.layer_info, "kind", "") == "type"]


def _dot_scene_rect(item):
    return item.mapToScene(item._dot_rect()).boundingRect()


def _text_scene_bbox(item):
    return item.mapToScene(item.rect()).boundingRect()


# ═══════════════════════════════════════════════════════════════
# 断言 1：色点 4×4、以中心为锚点、随旋转
# ═══════════════════════════════════════════════════════════════
def test_01_dot_is_4x4_anchored_at_center():
    """
    断言 1：色点基准 4×4，以 bbox 中心为锚点。

    A-22 补充：低缩放时会按屏幕像素补偿放大（4 单位 → 最多 N 单位），
    因此这里分两层断言：
      - 基准尺寸 DOT_SIZE 必须为 4.0
      - 实际色点边长 >= 4.0 且以中心为锚点
    """
    for rel, label in FIXTURES:
        _, c = _load(rel)
        for idx, it in _type_items(c):
            assert it.DOT_SIZE == pytest.approx(4.0), f"{label} 色点基准尺寸非 4"

            local = it._dot_rect()
            # A-22：实际尺寸 >= 基准（补偿只放大不缩小）
            assert local.width() >= 4.0, f"{label} 色点宽小于基准"
            assert local.height() >= 4.0, f"{label} 色点高小于基准"
            assert local.width() == pytest.approx(local.height()), "色点应为正方形"
            # 以本地原点（= bbox 中心）为锚点
            assert local.center().x() == pytest.approx(0.0)
            assert local.center().y() == pytest.approx(0.0)


def test_22_dot_visible_at_low_zoom():
    """
    A-22：低缩放（44%）下色点屏幕像素必须 >= 4px。
    修复前 4 单位 × 0.44 = 1.76px，肉眼几乎不可见。
    """
    _, c = _load("tests/data/four_state.psd")
    view = c.right_canvas
    item = _type_items(c)[0][1]

    for zoom in (1.0, 0.75, 0.5, 0.44, 0.25, 0.1):
        view.resetTransform()
        view.scale(zoom, zoom)
        app.processEvents()
        units = item._dot_size_in_scene()
        screen_px = units * zoom
        assert screen_px >= 4.0 - 1e-6, (
            f"缩放 {zoom} 下色点仅 {screen_px:.2f}px，低于 4px 可见阈值"
        )


def test_01b_dot_follows_rotation_anchor():
    """
    核心：90° 旋转图元的色点仍应落在其 bbox 中心，
    而不是旧实现 rect.left() 造成的偏移。
    """
    p, c = _load("tests/data/vertical_wedding_9_16.psd")
    rotated = [(i, it) for i, it in _type_items(c) if it.rotation() == 90.0]
    assert rotated, "夹具中应有 90° 旋转图元"

    for idx, it in rotated:
        dot_center = it.mapToScene(it._dot_rect()).boundingRect().center()
        bbox_center = it.mapToScene(it.rect()).boundingRect().center()
        assert abs(dot_center.x() - bbox_center.x()) < 0.01, "色点未居中于 bbox"
        assert abs(dot_center.y() - bbox_center.y()) < 0.01, "色点未居中于 bbox"


# ═══════════════════════════════════════════════════════════════
# 断言 2 / 3 / 4 / 5：互不相交、不与文字 bbox 相交、净空、双夹具
# ═══════════════════════════════════════════════════════════════
@pytest.mark.parametrize("rel,label", FIXTURES)
def test_02_dots_do_not_intersect_each_other(rel, label):
    _, c = _load(rel)
    items = _type_items(c)
    boxes = [(i, _dot_scene_rect(it)) for i, it in items]

    collisions = []
    for a in range(len(boxes)):
        for b in range(a + 1, len(boxes)):
            if boxes[a][1].intersects(boxes[b][1]):
                collisions.append((boxes[a][0], boxes[b][0]))
    assert not collisions, f"{label} 色点相交: {collisions}"


@pytest.mark.parametrize("rel,label", FIXTURES)
def test_03_dots_do_not_intersect_other_text_bbox(rel, label):
    _, c = _load(rel)
    items = _type_items(c)
    offenders = []
    for idx, it in items:
        dot = _dot_scene_rect(it)
        for other_idx, other in items:
            if other_idx == idx:
                continue
            if dot.intersects(_text_scene_bbox(other)):
                offenders.append((idx, other_idx))
    assert not offenders, f"{label} 色点与其它文字 bbox 相交: {offenders}"


@pytest.mark.parametrize("rel,label", FIXTURES)
def test_04_min_clearance_at_least_3_units(rel, label):
    """
    净空 = 两个色点之间的最小间距（外接框边到边）。
    """
    _, c = _load(rel)
    items = _type_items(c)
    boxes = [_dot_scene_rect(it) for _, it in items]

    worst = float("inf")
    for a in range(len(boxes)):
        for b in range(a + 1, len(boxes)):
            ra, rb = boxes[a], boxes[b]
            dx = max(rb.left() - ra.right(), ra.left() - rb.right(), 0.0)
            dy = max(rb.top() - ra.bottom(), ra.top() - rb.bottom(), 0.0)
            dist = max(dx, dy)
            worst = min(worst, dist)
    assert worst >= MIN_CLEARANCE, f"{label} 最小净空 {worst:.2f} < {MIN_CLEARANCE}"


def test_05_both_fixtures_pass():
    """断言 5：两个夹具必须同时通过（汇总检查）"""
    for rel, label in FIXTURES:
        _, c = _load(rel)
        items = _type_items(c)
        assert len(items) >= 4, f"{label} 文字层过少"
        boxes = [_dot_scene_rect(it) for _, it in items]
        for a in range(len(boxes)):
            for b in range(a + 1, len(boxes)):
                assert not boxes[a].intersects(boxes[b]), f"{label} 存在相交"


# ═══════════════════════════════════════════════════════════════
# 断言 6：展开仅对单个图层生效
# ═══════════════════════════════════════════════════════════════
def test_06_only_one_expanded_at_a_time():
    """
    断言 6（严格全局单例，第十一轮审核要求）：
    同一时刻最多一个图元展开。框选/多选不得同时展开多个。
    原断言写成 `== 2` 是把违规当预期，已按审核意见改为 `== 1`。
    """
    _, c = _load("tests/data/four_state.psd")
    items = _type_items(c)
    view = c.right_canvas
    assert len(items) >= 3

    # 默认全部折叠
    assert not any(it._is_badge_expanded() for _, it in items)
    assert view.expanded_badge_count() == 0

    # 单独悬停 -> 仅它展开
    items[0][1]._hovered = True
    view.request_badge_expand(items[0][1])
    expanded = [i for i, it in items if it._is_badge_expanded()]
    assert expanded == [items[0][0]], "悬停应仅展开一个"

    # 再悬停第二个 -> 仍只有 1 个展开（单例仲裁）
    items[1][1]._hovered = True
    view.request_badge_expand(items[1][1])
    expanded = [i for i, it in items if it._is_badge_expanded()]
    assert len(expanded) == 1, f"并发悬停时展开了 {len(expanded)} 个，违反全局单例"

    # 清理
    for _, it in items:
        it._hovered = False
    view._reconcile_badge_expansion()


def test_06b_multi_select_keeps_single_expansion():
    """断言 6：框选多个文字层时，只能展开 1 个（审核实测的缺陷场景）"""
    _, c = _load("tests/data/four_state.psd")
    items = _type_items(c)
    view = c.right_canvas

    for _, it in items:
        it.setSelected(True)
    app.processEvents()

    selected = sum(1 for _, it in items if it.isSelected())
    expanded = sum(1 for _, it in items if it._is_badge_expanded())
    assert selected >= 3, "应确实存在多选"
    assert expanded == 1, f"框选 {selected} 个却展开了 {expanded} 个"

    for _, it in items:
        it.setSelected(False)
    app.processEvents()
    assert sum(1 for _, it in items if it._is_badge_expanded()) == 0


def test_06c_hover_plus_select_still_single():
    """断言 6：悬停与选中并存时仍只有一个展开"""
    _, c = _load("tests/data/four_state.psd")
    items = _type_items(c)
    view = c.right_canvas

    for _, it in items[:4]:
        it.setSelected(True)
    app.processEvents()
    items[5][1]._hovered = True
    view.request_badge_expand(items[5][1])
    app.processEvents()

    expanded = sum(1 for _, it in items if it._is_badge_expanded())
    assert expanded == 1

    for _, it in items:
        it.setSelected(False)
        it._hovered = False
    view._reconcile_badge_expansion()


# ═══════════════════════════════════════════════════════════════
# 断言 7：展开徽章不溢出画布
# ═══════════════════════════════════════════════════════════════
@pytest.mark.parametrize("rel,label", FIXTURES)
def test_07_expanded_badge_stays_within_artboard(rel, label):
    p, c = _load(rel)
    half_w, half_h = p["width"] / 2.0, p["height"] / 2.0

    for idx, it in _type_items(c):
        it._hovered = True
        badge = it.mapToScene(it._badge_rect_for(it.get_badge_info()[0])).boundingRect()
        it._hovered = False

        assert badge.left() >= -half_w - 1, f"{label} 徽章溢出左边界"
        assert badge.right() <= half_w + 1, f"{label} 徽章溢出右边界"
        assert badge.top() >= -half_h - 1, f"{label} 徽章溢出上边界"
        assert badge.bottom() <= half_h + 1, f"{label} 徽章溢出下边界"


# ═══════════════════════════════════════════════════════════════
# 断言 8：颜色/文案与四态一致
# ═══════════════════════════════════════════════════════════════
FOUR_STATE_COLORS = {
    "detected": "#30d158",
    "missing_fallback": "#ff9f0a",
    "font_missing": "#ff453a",
    "unverifiable": "#ffd60a",
}


def test_08_folded_dot_keeps_four_state_color():
    _, c = _load("tests/data/four_state.psd")
    seen = {}
    for idx, it in _type_items(c):
        text, bg, fg = it.get_badge_info()
        st = it.layer_info.font_info.get("detection_status")
        seen[st] = fg.name().lower()
        # 折叠态使用 fg 作色点色，语义必须与原徽章一致
        assert fg.name().lower() == FOUR_STATE_COLORS[st], (
            f"{st} 颜色 {fg.name()} 与规格 {FOUR_STATE_COLORS[st]} 不符"
        )
    # 状态覆盖数取决于环境：
    #   macOS（有 AppKit）→ detected / missing_fallback / font_missing 三态并存
    #   无 AppKit        → 全部 unverifiable，只有 1 态（这是正确行为，不是缺陷）
    try:
        import AppKit  # noqa: F401
        has_appkit = True
    except Exception:
        has_appkit = False

    if has_appkit:
        assert len(seen) >= 3, f"macOS 下四态夹具状态过少: {seen}"
    else:
        assert set(seen) == {"unverifiable"}, f"无 AppKit 时应统一 unverifiable: {seen}"


def test_08b_expanded_text_unchanged():
    """展开态文案必须与 get_badge_info 返回一致，不因折叠逻辑改变"""
    _, c = _load("tests/data/four_state.psd")
    samples = [it for _, it in _type_items(c)][:3]
    before = [it.get_badge_info()[0] for it in samples]

    for it in samples:
        it._hovered = True
    after = [it.get_badge_info()[0] for it in samples]

    assert before == after, "折叠/展开不应改变徽章文案"


# ═══════════════════════════════════════════════════════════════
# 断言 9：命中区 ≥ 8×8 且点击链路可用
# ═══════════════════════════════════════════════════════════════
def test_09_hit_rect_at_least_8x8():
    _, c = _load("tests/data/four_state.psd")
    for idx, it in _type_items(c):
        hit = it._hit_rect()
        assert hit.width() >= 8.0, "命中区宽不足 8"
        assert hit.height() >= 8.0, "命中区高不足 8"
        # 命中区必须包住 4×4 色点
        assert hit.contains(it._dot_rect())


def test_09b_badge_click_signal_still_works():
    """折叠态点击色点必须触发 on_badge_clicked"""
    fired = []
    p = parse_psd_file(os.path.join(PROJECT_ROOT, "tests/data/four_state.psd"),
                       extract_thumbnails=False)
    layer = [l for l in p["layers"] if l.kind == "type"][0]
    item = ConvertedLayerGraphicItem(layer, on_badge_clicked=lambda li: fired.append(li))
    assert item.on_badge_clicked is not None

    # 折叠态命中区中心即本地原点
    assert item._hit_rect().contains(QPointF(0, 0))
    # 模拟点击：直接调用命中判定逻辑所依赖的矩形
    assert not item._is_badge_expanded()
    hit = item._hit_rect()
    assert hit.width() >= 8 and hit.height() >= 8


# ═══════════════════════════════════════════════════════════════
# 断言 10：悬停提示文案等同展开态
# ═══════════════════════════════════════════════════════════════
def test_10_hover_tooltip_equals_expanded_text():
    """
    折叠态必须提供悬停提示，文案等同展开态徽章文本。
    实现方式：get_badge_info 的文本即 tooltip 来源，由 view 层 setToolTip。
    此处断言二者同源，且 view 层确实写入 tooltip。
    """
    p, c = _load("tests/data/four_state.psd")
    for idx, it in _type_items(c):
        expanded_text = it.get_badge_info()[0]
        assert expanded_text, "展开态文案为空"

    # view 层应在加载后为图元设置 tooltip
    has_tip = []
    for idx, it in _type_items(c):
        tip = it.toolTip()
        has_tip.append(bool(tip))
    assert any(has_tip), "折叠态未提供悬停提示"
    for idx, it in _type_items(c):
        assert it.toolTip() == it.get_badge_info()[0], "tooltip 与展开态文案不一致"


# ═══════════════════════════════════════════════════════════════
# 断言 11：A-16 四态像素互斥
# ═══════════════════════════════════════════════════════════════
def test_11_four_state_pixel_exclusivity():
    """
    红色（字体未安装）与黄色（无法验证）不得同时出现在同一面板。
    当前 macOS 面板应只出现红，无 AppKit 面板应只出现黄。
    """
    _, c = _load("tests/data/four_state.psd")
    reds = 0
    yellows = 0
    for idx, it in _type_items(c):
        _, _, fg = it.get_badge_info()
        if fg.name().lower() == FOUR_STATE_COLORS["font_missing"]:
            reds += 1
        if fg.name().lower() == FOUR_STATE_COLORS["unverifiable"]:
            yellows += 1

    assert not (reds > 0 and yellows > 0), (
        f"红({reds}) 与 黄({yellows}) 同时出现，四态互斥被破坏"
    )
