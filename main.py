#!/usr/bin/env python3
"""
FCPX Studio Pro 桌面应用启动入口
"""
import sys
import os

# 将项目目录加入 sys.path
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

from PyQt6.QtWidgets import QApplication
from PyQt6.QtGui import QFont
from gui.main_window import MainWindow

def main():
    app = QApplication(sys.argv)
    app.setApplicationName("FCPX Studio Pro")
    app.setOrganizationName("StudioPro")

    # 全局字体
    font = QFont("PingFang SC", 12)
    app.setFont(font)

    window = MainWindow()
    window.show()

    sys.exit(app.exec())

if __name__ == "__main__":
    main()
