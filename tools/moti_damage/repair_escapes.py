#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
坏 .moti 属性转义修复（问题单 C·后续：备份前提下修源文件）。

只做精确子串替换：把 name 属性值里未转义的 " / < / > 转成
&quot; / &lt; / &gt;；不触碰 XML 标签定界符，不重排字节。

用法：
    python3 repair_escapes.py            # 校验基线 + 修复 + 复解析
    python3 repair_escapes.py --check     # 只校验基线与可解析，不写盘

前置：6 件已先复制到 App Support/moti_backups/（见备份留证）。
"""
import hashlib
import os
import sys
import xml.etree.ElementTree as ET

BASE = os.path.expanduser(
    "~/Movies/Motion Templates.localized/Titles.localized/03综艺动漫"
)

# (路径相对 BASE, 修复前基线 sha256, 旧子串, 新子串)
REPAIRS = [
    (
        "不要T战斗/点文本/点 03/点 03.moti",
        "46d34e5b90e9801098f1a3e5d69effbd5fe2f2f05af462745f31a96b90097f28",
        'name="正焕如此欢迎的"尊贵的人"是"',
        'name="正焕如此欢迎的&quot;尊贵的人&quot;是"',
    ),
    (
        "不要T战斗/点文本/点 07/点 07.moti",
        "8448a5f7bf65036397e4707f9b378974a852512da96738de1a925525fabde244",
        'name="正焕如此欢迎的"尊贵的人"是"',
        'name="正焕如此欢迎的&quot;尊贵的人&quot;是"',
    ),
    (
        "会议广场/点文本/点文本 03/点文本 03.moti",
        "9d6ca91f6afee663961b83c54c2f934d027255057b6fac3810f2f79fc4d0feef",
        'name="<OhMyGirl>忙内Arin"',
        'name="&lt;OhMyGirl&gt;忙内Arin"',
    ),
    (
        "尹住宿/条/菜单条修复/菜单条修复.moti",
        "bf9102a01d5cf293131e5edf853be4ef8a7f68ab9b642330334a92e595341fe1",
        'name="<宫中年糕汤准备>"',
        'name="&lt;宫中年糕汤准备&gt;"',
    ),
    (
        "尹住宿/条/菜单条自定义/菜单条自定义.moti",
        "fc1867290e845558414fcae5b380ed921179364e855b2e200183ae4f24703248",
        'name="<宫中年糕汤准备>"',
        'name="&lt;宫中年糕汤准备&gt;"',
    ),
]


def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def main() -> int:
    check_only = "--check" in sys.argv
    rc = 0
    for rel, base_sha, old, new in REPAIRS:
        path = os.path.join(BASE, rel)
        raw = open(path, "rb").read()
        before = sha256(raw)
        if before != base_sha:
            print(f"BASELINE_MISMATCH\t{os.path.basename(path)}\t{before[:16]}")
            rc = 1
            continue
        text = raw.decode("utf-8")
        count = text.count(old)
        if count == 0:
            print(f"OLD_NOT_FOUND\t{os.path.basename(path)}")
            rc = 1
            continue
        if check_only:
            print(f"CHECK_OK\t{os.path.basename(path)}\t命中 {count} 处")
            continue
        fixed = text.replace(old, new)
        out = fixed.encode("utf-8")
        # 复解析校验
        try:
            ET.fromstring(out)
        except ET.ParseError as e:
            print(f"PARSE_FAIL\t{os.path.basename(path)}\t{e}")
            rc = 1
            continue
        open(path, "wb").write(out)
        after = sha256(out)
        print(f"FIXED\t{os.path.basename(path)}\t替换 {count} 处\t{before[:16]} -> {after[:16]}\t{len(raw)}B -> {len(out)}B")
    return rc


if __name__ == "__main__":
    sys.exit(main())
