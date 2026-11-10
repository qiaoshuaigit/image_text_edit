"""纯逻辑单测：不加载 OCR 模型、不启动界面（依赖缺失时用轻量桩，无环境也能跑）"""
import sys
import types
import unittest
from pathlib import Path

import numpy as np
import pandas as pd


def _install_stub(name, attrs):
    mod = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(mod, k, v)
    sys.modules[name] = mod


# 桩：cv2 缺失时用最小实现，只保证纯逻辑函数可导入可测
try:
    import cv2  # noqa: F401
except ImportError:
    _install_stub("cv2", {
        "COLOR_BGR2RGB": 0, "COLOR_RGB2BGR": 1, "COLOR_BGR2GRAY": 2, "COLOR_RGB2GRAY": 2,
        "INTER_AREA": 0, "INPAINT_TELEA": 0, "FONT_HERSHEY_SIMPLEX": 0,
        "cvtColor": lambda img, code: img[..., ::-1] if code == 0 else img,
        "resize": lambda img, size, interpolation=0: img,
        "dilate": lambda m, k, iterations=1: m,
        "inpaint": lambda img, mask, r, flag: img,
        "rectangle": lambda *a, **k: None,
        "putText": lambda *a, **k: None,
        "imwrite": lambda *a, **k: True,
    })


# 桩：gradio 缺失时用最小实现，只用于导入模块
try:
    import gradio  # noqa: F401
except ImportError:
    class _Ctx:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    class _Any:
        def __init__(self, *a, **k):
            pass

        def click(self, *a, **k):
            pass

        def change(self, *a, **k):
            pass

    _gr = {}
    for _n in ["Blocks", "Row", "Column", "File", "Button", "Markdown", "Textbox",
               "Number", "Dropdown", "Radio", "ColorPicker", "Image", "Dataframe"]:
        _gr[_n] = type(_n, (_Any, _Ctx), {})
    _gr["update"] = lambda **k: k
    _install_stub("gradio", _gr)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
import image_text_editor as ite


_ORIG_RENDERER = ite.renderer


def make_table(rows):
    return pd.DataFrame(rows, columns=ite.HEADERS)


class TestHelpers(unittest.TestCase):
    def test_parse_font_size(self):
        self.assertEqual(ite._parse_font_size(0), (0, False))
        self.assertEqual(ite._parse_font_size("48"), (48, False))
        self.assertEqual(ite._parse_font_size("48.0"), (48, False))
        self.assertEqual(ite._parse_font_size(""), (0, False))
        self.assertEqual(ite._parse_font_size(None), (0, False))
        self.assertEqual(ite._parse_font_size(np.nan), (0, False))
        self.assertEqual(ite._parse_font_size("nan"), (0, False))
        self.assertEqual(ite._parse_font_size("abc"), (0, True))
        self.assertEqual(ite._parse_font_size(-5), (0, False))

    def test_batch_set_font_size(self):
        df = make_table([[0, "a", "10x10", "不改", "", 0], [1, "b", "10x10", "不改", "", 0]])
        out, msg = ite.batch_set_font_size(df, 60)
        self.assertEqual(list(out[ite.COL_SIZE]), [60, 60])
        self.assertIn("60", msg)
        out2, msg2 = ite.batch_set_font_size(df, "abc")
        self.assertEqual(list(out2[ite.COL_SIZE]), [0, 0])
        self.assertIn("数字", msg2)

    def test_find_replace_case_insensitive(self):
        # find_replace 会先按 OCR 结果纠正参考列，这里准备对应的 OCR 数据
        texts = [{"text": "Fibrosis", "w": 10, "h": 10, "x_min": 0, "y_min": 0, "x_max": 10, "y_max": 10},
                 {"text": "Other", "w": 10, "h": 10, "x_min": 20, "y_min": 0, "x_max": 30, "y_max": 10},
                 {"text": "mild Fibrosis x", "w": 10, "h": 10, "x_min": 40, "y_min": 0, "x_max": 50, "y_max": 10}]
        ite._state["texts"] = texts
        df = make_table([[0, "Fibrosis", "10x10", "不改", "", 0],
                         [1, "Other", "10x10", "不改", "", 0],
                         [2, "mild Fibrosis x", "10x10", "不改", "", 0]])
        out = ite.find_replace(df, "fibrosis", "纤维化")
        self.assertEqual(out.at[0, ite.COL_ACTION], "替换")
        self.assertEqual(out.at[0, ite.COL_NEW], "纤维化")
        self.assertEqual(out.at[1, ite.COL_ACTION], "不改")
        self.assertEqual(out.at[2, ite.COL_NEW], "mild 纤维化 x")
        ite._state["texts"] = []

    def test_empty_table_has_id_column(self):
        self.assertEqual(list(ite.empty_table().columns), ite.HEADERS)


class TestPtToPx(unittest.TestCase):
    def test_auto_is_zero(self):
        self.assertEqual(ite.pt_to_px(0), 0)

    def test_default_dpi(self):
        # 96dpi：12pt = 16px
        self.assertEqual(ite.pt_to_px(12), 16)

    def test_custom_dpi(self):
        # 300dpi 印刷：12pt = 50px
        self.assertEqual(ite.pt_to_px(12, 300), 50)

    def test_300dpi_equals_4x(self):
        self.assertEqual(ite.pt_to_px(9, 300), 38)


class TestFontFamily(unittest.TestCase):
    """字体解析：所选字体不可用时按 粗体→同族→回退 解析，不能崩"""

    def setUp(self):
        renderer = ite.TextRenderer()
        renderer.fonts = {"Arial": ("a.ttf", "a.ttf"), "宋体": ("s.ttc", "s.ttc")}
        ite.renderer = renderer

    def tearDown(self):
        ite.renderer = _ORIG_RENDERER

    def test_exact_match(self):
        self.assertEqual(ite._font_path("Arial"), "a.ttf")
        self.assertEqual(ite._font_path("宋体"), "s.ttc")

    def test_bold_suffix_uses_regular_when_no_bold(self):
        self.assertEqual(ite._font_path("Arial Bold"), "a.ttf")
        self.assertEqual(ite._font_path("宋体粗体"), "s.ttc")

    def test_bold_suffix_prefers_bold_file(self):
        ite.renderer.fonts["Arial"] = ("a.ttf", "ab.ttf")
        self.assertEqual(ite._font_path("Arial Bold"), "ab.ttf")

    def test_english_bold_real_names(self):
        ite.renderer.fonts = {"Arial Bold": ("ab.ttf", "ab.ttf")}
        self.assertEqual(ite._font_path("Arial Bold"), "ab.ttf")

    def test_unknown_name_falls_back(self):
        self.assertEqual(ite._font_path("不存在的字体"), "a.ttf")

    def test_empty_fonts_returns_none(self):
        ite.renderer.fonts = {}
        self.assertIsNone(ite._font_path("Arial"))


class TestGenerateById(unittest.TestCase):
    """区域ID 匹配：删行、改行序都不应擦错位置"""

    def setUp(self):
        ite._state["orig_bgr"] = np.full((20, 20, 3), 200, np.uint8)
        ite._state["display_bgr"] = np.zeros((20, 20, 3), np.uint8)
        ite._state["display_scale"] = 1.0
        ite._state["last_result_bgr"] = None
        ite._state["dpi"] = 96
        ite._state["texts"] = [
            {"text": "A", "w": 4, "h": 4, "x_min": 0, "y_min": 0, "x_max": 4, "y_max": 4},
            {"text": "B", "w": 4, "h": 4, "x_min": 10, "y_min": 10, "x_max": 14, "y_max": 14},
        ]

    def test_generate_returns_rgb(self):
        df = make_table([[0, "A", "4x4", "不改", "", 0]])
        out, msg = ite.do_generate(df, "Arial", "auto", "#000000")
        self.assertEqual(out.shape, (20, 20, 3))
        self.assertIn("0 处替换", msg)

    def test_generate_reordered_rows(self):
        df = make_table([[1, "B", "4x4", "移除", "", 0], [0, "A", "4x4", "不改", "", 0]])
        out, msg = ite.do_generate(df, "Arial", "auto", "#000000")
        self.assertNotIn("不在识别结果", msg)

    def test_invalid_id_is_repaired(self):
        # 区域ID 被改成非法值（超出识别范围）时，按行序自动纠正，不会改错位置
        df = make_table([[99, "?", "4x4", "移除", "", 0]])
        fixed = ite.normalize_table(df)
        self.assertEqual(int(fixed.at[0, ite.COL_ID]), 0)
        self.assertEqual(fixed.at[0, ite.COL_TEXT], "A")
        self.assertEqual(fixed.at[0, ite.COL_BOX], "4x4")

    def test_normalize_restores_reference_columns(self):
        # 识别文字/原始框 被误改时，以 OCR 结果为准纠正回来
        df = make_table([[1, "被改坏了", "999x999", "不改", "", 0]])
        fixed = ite.normalize_table(df)
        self.assertEqual(fixed.at[0, ite.COL_TEXT], "B")
        self.assertEqual(fixed.at[0, ite.COL_BOX], "4x4")

    def test_normalize_keeps_edit_columns(self):
        # 用户可编辑的三列必须原样保留
        df = make_table([[1, "B", "4x4", "替换", "NewText", 18]])
        fixed = ite.normalize_table(df)
        self.assertEqual(fixed.at[0, ite.COL_ACTION], "替换")
        self.assertEqual(fixed.at[0, ite.COL_NEW], "NewText")
        self.assertEqual(int(fixed.at[0, ite.COL_SIZE]), 18)

    def test_normalize_deleted_row_does_not_shift(self):
        # 删掉第一行后剩下的行仍按自身区域ID生效，不会顶替成第0行
        df = make_table([[1, "B", "4x4", "移除", "", 0]])
        fixed = ite.normalize_table(df)
        self.assertEqual(int(fixed.at[0, ite.COL_ID]), 1)
        out, msg = ite.do_generate(fixed, "Arial", "auto", "#000000")
        self.assertNotIn("不在识别结果", msg)

    def test_generate_reports_bad_font_size(self):
        df = make_table([[0, "A", "4x4", "替换", "X", "abc"]])
        out, msg = ite.do_generate(df, "Arial", "auto", "#000000")
        self.assertIn("字号无法识别", msg)

    def test_generate_without_texts_returns_rgb(self):
        ite._state["texts"] = []
        df = make_table([[0, "A", "4x4", "移除", "", 0]])
        out, msg = ite.do_generate(df, "Arial", "auto", "#000000")
        self.assertEqual(out.shape, (20, 20, 3))
        self.assertIn("检测文字", msg)


if __name__ == "__main__":
    unittest.main(verbosity=2)
