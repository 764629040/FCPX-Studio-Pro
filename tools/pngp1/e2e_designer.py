"""P1 设计器端到端（无头）验证：PNG 拆分目录 → 画布/检查器 → 生成 .moti。

用 offscreen 平台跑真实 MainWindow，但把「导出到 ~/Movies 并挂软链」换成 /tmp，
并用 stub 顶掉会阻塞的 QMessageBox。不改产品代码，只 patch 测试期的副作用。
"""

import os
import sys
import json
import shutil

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

from PyQt6.QtWidgets import QApplication, QMessageBox, QFileDialog  # noqa: E402
from PyQt6.QtCore import QSettings  # noqa: E402

import gui.main_window as mw  # noqa: E402

SPLIT_ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1
                             else "reports/verify_pngp1/outputs")
OUT_ROOT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "/tmp/pngp1_gui_e2e")


def stub_messages():
    logs = []

    def _info(parent, title, text, *a, **k):
        logs.append(("information", title, text))
        return QMessageBox.StandardButton.Ok

    def _warn(parent, title, text, *a, **k):
        logs.append(("warning", title, text))
        return QMessageBox.StandardButton.Ok

    def _crit(parent, title, text, *a, **k):
        logs.append(("critical", title, text))
        return QMessageBox.StandardButton.Ok

    def _question(parent, title, text, *a, **k):
        logs.append(("question", title, text))
        return QMessageBox.StandardButton.Yes

    QMessageBox.information = staticmethod(_info)
    QMessageBox.warning = staticmethod(_warn)
    QMessageBox.critical = staticmethod(_crit)
    QMessageBox.question = staticmethod(_question)
    return logs


def main():
    stub_messages()
    # 不写用户 ~/Movies：导出目录换成 /tmp，并让软链挂载变成空操作
    os.makedirs(OUT_ROOT, exist_ok=True)
    mw.DEFAULT_EXTERNAL_DIR = OUT_ROOT
    mw._resolve_export_group_dir = lambda root, group: os.path.join(root, group)

    app = QApplication(sys.argv)
    QSettings("FCPXStudioPro", "P1E2E")  # 独立 settings 命名空间，避免污染

    win = mw.MainWindow()
    win.symlink_mgr.link_category_to_system = lambda *a, **k: None

    rows = []
    win._load_psd_dir(SPLIT_ROOT)
    listed = list(win.psd_file_list)
    print("列出条目数:", len(listed))

    for idx, item_path in enumerate(listed):
        name = os.path.basename(item_path)
        win.psd_list_widget.setCurrentRow(idx)
        win._on_psd_selected(idx)  # offscreen 下不依赖信号，直接走同一条产品分支
        info = win.current_parsed_psd
        # 窗口没 show()，isVisible() 恒为 False；用 isHidden() 判「是否被显式隐藏」
        banner = not win.bitmap_notice_banner.isHidden()
        err = not win.error_banner.isHidden()
        notice_txt = win.lbl_bitmap_notice.text()
        canvas_items = len(win.canvas_view.left_canvas.items_map)
        tree_top = win.inspector.tree.topLevelItemCount()
        rows.append({
            "name": name,
            "layers": info["layer_count"],
            "canvas_items": canvas_items,
            "inspector_rows": tree_top,
            "banner_visible": banner,
            "error_banner": err,
            "error_text": win.lbl_error_msg.text() if err else "",
            "notice": notice_txt,
            "size": [info["width"], info["height"]],
        })
        print("  %-32s 层=%-3d 画布=%-3d 检查器=%-3d 横幅=%s%s"
              % (name, info["layer_count"], canvas_items, tree_top,
                 "ON" if banner else "OFF",
                 ("  错误态: " + win.lbl_error_msg.text()) if err else ""))

    # 挑一个四类齐全的样本走完整导出
    target = None
    for idx, item_path in enumerate(listed):
        if "A_gradient" in item_path:
            target = idx
            break
    if target is None and listed:
        target = 0

    export = {"ran": False}
    if target is not None:
        win.psd_list_widget.setCurrentRow(target)
        name = os.path.basename(win.psd_file_list[target])
        win._on_save_current_template()
        tpl_dir = os.path.join(OUT_ROOT, "PSD婚礼字幕", name)
        moti = os.path.join(tpl_dir, name + ".moti")
        export = {
            "ran": True,
            "name": name,
            "template_dir": tpl_dir,
            "moti_exists": os.path.isfile(moti),
            "moti_bytes": os.path.getsize(moti) if os.path.isfile(moti) else 0,
            "media_count": len(os.listdir(os.path.join(tpl_dir, "Media")))
            if os.path.isdir(os.path.join(tpl_dir, "Media")) else 0,
            "large_png_bytes": os.path.getsize(os.path.join(tpl_dir, "large.png"))
            if os.path.isfile(os.path.join(tpl_dir, "large.png")) else 0,
            "current_moti_path": win.current_moti_path,
        }
        print("导出:", json.dumps(export, ensure_ascii=False))

    print("\n=== SUMMARY JSON ===")
    print(json.dumps({"listed": len(listed), "rows": rows, "export": export},
                     ensure_ascii=False, indent=1))

    # 界面证据截图（offscreen 渲染真实窗口，不是画示意图）
    shot_dir = os.path.join(OUT_ROOT, "shots")
    os.makedirs(shot_dir, exist_ok=True)
    win.resize(1680, 1020)
    win.show()
    app.processEvents()
    shots = []
    for idx, item_path in enumerate(listed):
        if "A_gradient" not in item_path and "E_ui" not in item_path:
            continue
        win.psd_list_widget.setCurrentRow(idx)
        win._on_psd_selected(idx)
        app.processEvents()
        name = os.path.basename(item_path)
        p = os.path.join(shot_dir, "设计器_%s.png" % name)
        win.grab().save(p)
        shots.append(p)
    print("截图:", json.dumps(shots, ensure_ascii=False))


if __name__ == "__main__":
    main()
