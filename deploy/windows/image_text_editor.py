"""
图片改字工具 v6 - 大文件支持版
用文件上传方式，后端自动缩放显示，原图保留用于高清导出

v6 修复：
  1. 表格行与 OCR 区域按「区域ID」绑定，不再依赖行号，删行/加行/换图都不会擦错位置
  2. 重新加载图片、重新检测时自动清空操作表
  3. 导出目录按程序位置定位，文件名带时间戳，不再覆盖历史结果
  4. 未识别到文字时返回三通道图，修复预览偏色
  5. 字号统一按 pt 计算：界面输入 pt，按图片 DPI 换算成像素后渲染
  6. 字体选择修复：所选字体不可用时回退到同族常规体/粗体，不再一律落到第一个字体
  7. 字号非法值给出状态提示，不再静默变成自动字号
"""
import os
import re
import time
import tempfile
import cv2
import numpy as np
import pandas as pd
from PIL import Image, ImageDraw, ImageFont
import gradio as gr

Image.MAX_IMAGE_PIXELS = None

def _font_candidate(*paths):
    """按顺序返回第一个存在的字体文件；全部不存在则返回 None"""
    for path in paths:
        if path and os.path.exists(path):
            return path
    return None


# 字体族 → (常规体, 粗体)；None 表示没有独立粗体文件
# Linux 上 CentOS 的 Noto 包提供 OTF，Ubuntu 提供 TTC，这里同时兼容
FONT_MAP = {
    "微软雅黑": (_font_candidate(r"C:\Windows\Fonts\msyh.ttc"),
                 _font_candidate(r"C:\Windows\Fonts\msyhbd.ttc")),
    "黑体": (_font_candidate(r"C:\Windows\Fonts\simhei.ttf"), None),
    "宋体": (_font_candidate(r"C:\Windows\Fonts\simsun.ttc"), None),
    "楷体": (_font_candidate(r"C:\Windows\Fonts\simkai.ttf"), None),
    "Arial": (_font_candidate(r"C:\Windows\Fonts\arial.ttf"),
              _font_candidate(r"C:\Windows\Fonts\arialbd.ttf")),
    "Arial Black": (_font_candidate(r"C:\Windows\Fonts\ariblk.ttf"), None),
    "Times New Roman": (_font_candidate(r"C:\Windows\Fonts\times.ttf"),
                        _font_candidate(r"C:\Windows\Fonts\timesbd.ttf")),
    "Noto Sans CJK SC": (
        _font_candidate(
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf",
            "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/google-noto-cjk/NotoSansCJKsc-Regular.otf",
            "/usr/share/fonts/google-noto/NotoSansCJKsc-Regular.otf",
            "/usr/share/fonts/google-noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        ),
        _font_candidate(
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
            "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Bold.otf",
            "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Bold.ttc",
            "/usr/share/fonts/google-noto-cjk/NotoSansCJKsc-Bold.otf",
            "/usr/share/fonts/google-noto/NotoSansCJKsc-Bold.otf",
            "/usr/share/fonts/google-noto/NotoSansCJK-Bold.ttc",
            "/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc",
        ),
    ),
    "Noto Serif CJK SC": (
        _font_candidate(
            "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
            "/usr/share/fonts/opentype/noto/NotoSerifCJKsc-Regular.otf",
            "/usr/share/fonts/google-noto-cjk/NotoSerifCJK-Regular.ttc",
            "/usr/share/fonts/google-noto-cjk/NotoSerifCJKsc-Regular.otf",
            "/usr/share/fonts/google-noto/NotoSerifCJKsc-Regular.otf",
            "/usr/share/fonts/google-noto/NotoSerifCJK-Regular.ttc",
            "/usr/share/fonts/noto-cjk/NotoSerifCJK-Regular.ttc",
        ),
        _font_candidate(
            "/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc",
            "/usr/share/fonts/opentype/noto/NotoSerifCJKsc-Bold.otf",
            "/usr/share/fonts/google-noto-cjk/NotoSerifCJK-Bold.ttc",
            "/usr/share/fonts/google-noto-cjk/NotoSerifCJKsc-Bold.otf",
            "/usr/share/fonts/google-noto/NotoSerifCJKsc-Bold.otf",
            "/usr/share/fonts/google-noto/NotoSerifCJK-Bold.ttc",
            "/usr/share/fonts/noto-cjk/NotoSerifCJK-Bold.ttc",
        ),
    ),
    "DejaVu Sans": (
        _font_candidate(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
        ),
        _font_candidate(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        ),
    ),
    "文泉驿正黑": (
        _font_candidate(
            "/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc",
            "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
        ),
        None,
    ),
    "文泉驿微米黑": (
        _font_candidate(
            "/usr/share/fonts/wqy-microhei/wqy-microhei.ttc",
            "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        ),
        None,
    ),
}

DISPLAY_MAX_SIDE = 2000   # 显示用缩放后最长边
OCR_MAX_SIDE = 3000       # OCR 前图片最长边上限，超过先缩放
DEFAULT_DPI = 96          # 图片无 DPI 信息时按 96dpi 换算 pt→px
# 部署包可通过 OUTPUT_DIR 指定导出目录；默认仍是程序目录的上一级/output
OUTPUT_DIR = os.environ.get("OUTPUT_DIR") or os.path.abspath(
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "output"))

# 表格列（生成、渲染、界面共用一份定义，避免列名不一致）
COL_ID = "区域ID"
COL_TEXT = "识别文字"
COL_BOX = "原始框(px)"
COL_ACTION = "操作"
COL_NEW = "新文字"
COL_SIZE = "字号(pt)"
HEADERS = [COL_ID, COL_TEXT, COL_BOX, COL_ACTION, COL_NEW, COL_SIZE]


def empty_table():
    return pd.DataFrame(columns=HEADERS)


def normalize_table(df):
    """整理前端回传的表格，保证区域ID与行一一对应。

    前端允许增删行、也允许把参考列改成别的值，这里统一纠正：
    区域ID 只要不是合法整数就按行序补上；识别文字/原始框以 OCR 结果为准。
    """
    if df is None or len(df) == 0:
        return df
    df = df.copy().reset_index(drop=True)
    texts = _state['texts']
    for i, row in df.iterrows():
        try:
            rid = int(float(row[COL_ID]))
        except (KeyError, TypeError, ValueError):
            rid = -1
        if not 0 <= rid < len(texts):
            rid = i if i < len(texts) else -1
            df.at[i, COL_ID] = rid
        if 0 <= rid < len(texts):
            df.at[i, COL_TEXT] = texts[rid]['text']
            df.at[i, COL_BOX] = f"{texts[rid]['w']}x{texts[rid]['h']}"
    return df


def pt_to_px(pt, dpi=DEFAULT_DPI):
    """字号 pt → 渲染像素：1pt = 1/72 英寸，px = pt × dpi / 72；0 表示自动适配"""
    if not pt or pt <= 0:
        return 0
    return max(1, int(round(pt * (dpi or DEFAULT_DPI) / 72.0)))


class TextDetector:
    def __init__(self):
        self.ocr = None
        try:
            from rapidocr_onnxruntime import RapidOCR
            self.ocr = RapidOCR()
            print("[OK] RapidOCR 初始化成功")
        except Exception as e:
            print(f"[ERROR] {e}")

    def detect(self, image_bgr):
        if not self.ocr:
            return []
        # 临时文件放系统临时目录，避免工作目录留垃圾或不可写时崩溃
        fd, tmp_path = tempfile.mkstemp(suffix=".png")
        os.close(fd)
        try:
            cv2.imwrite(tmp_path, image_bgr)
            result, _ = self.ocr(tmp_path)
        finally:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
        texts = []
        if result:
            for line in result:
                box = line[0]
                xs = [p[0] for p in box]
                ys = [p[1] for p in box]
                texts.append({
                    'text': line[1], 'conf': float(line[2]),
                    'w': int(max(xs)-min(xs)), 'h': int(max(ys)-min(ys)),
                    'x_min': int(min(xs)), 'y_min': int(min(ys)),
                    'x_max': int(max(xs)), 'y_max': int(max(ys)),
                })
        return texts


class TextEraser:
    """只擦文字笔画，不用实心矩形，背景纹理得以保留"""

    def erase(self, image_bgr, mask, radius=3):
        if len(mask.shape) == 3:
            mask = cv2.cvtColor(mask, cv2.COLOR_RGB2GRAY)
        # 轻微膨胀 1px 盖住抗锯齿边缘；膨胀过多会把周围纹理一起抹掉
        # 向外扩 2px：把文字的抗锯齿过渡带一起覆盖，否则描边会残留成灰影
        mask = cv2.dilate(mask, np.ones((5, 5), np.uint8), iterations=1)
        return cv2.inpaint(image_bgr, mask, max(1, int(radius)), cv2.INPAINT_TELEA)

    @staticmethod
    def stroke_mask(roi_bgr, box_h):
        """在文字框内生成笔画级掩码。

        思路：文字与背景灰度差异大，用 Otsu 自适应阈值分出前景，
        再只保留足够大的连通块，避免把背景里的细小纹理误当文字擦掉。
        """
        gray = cv2.cvtColor(roi_bgr, cv2.COLOR_BGR2GRAY)
        _, dark = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        _, bright = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        total = gray.size or 1
        ratio_dark = int((dark > 0).sum()) / total
        ratio_bright = int((bright > 0).sum()) / total
        mask = dark if abs(ratio_dark - 0.2) <= abs(ratio_bright - 0.2) else bright

        min_area = max(3, int(box_h * box_h * 0.02))
        num, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
        clean = np.zeros_like(mask)
        for idx in range(1, num):
            if stats[idx, cv2.CC_STAT_AREA] >= min_area:
                clean[labels == idx] = 255
        return clean if clean.any() else mask

class TextRenderer:
    """只管字体解析与取色，绘制在 do_generate 里批量做"""

    def __init__(self):
        # 每个可见字体名 → (常规体路径, 粗体路径或None)；
        # 为避免"微软雅黑 Bold"与"微软雅黑"两个相似选项让用户混淆，只暴露常规体名字
        self.fonts = {}
        for name, (regular, bold) in FONT_MAP.items():
            if regular:
                self.fonts[name] = (regular, bold or regular)
        print(f"[OK] 字体: {list(self.fonts.keys())}")
        if len(self.fonts) < 2:
            print("[WARN] 可用字体不足 2 个，Linux 请执行 deploy/linux/install.sh 或 install_centos.sh 安装中文字体")

    def extract_color(self, img_bgr, x1, y1, x2, y2):
        roi = img_bgr[y1:y2, x1:x2]
        if roi.size == 0:
            return (0, 0, 0)
        gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
        dark = roi[gray <= np.percentile(gray, 20)]
        if dark.size == 0:
            return (0, 0, 0)
        return tuple(int(v) for v in np.mean(dark.reshape(-1, 3), axis=0))


detector = TextDetector()
eraser = TextEraser()
renderer = TextRenderer()
font_choices = list(renderer.fonts.keys()) or ["微软雅黑"]

# 全局状态：存原图和缩放显示图
_state = {
    'orig_bgr': None,
    'display_bgr': None,
    'display_scale': 1.0,
    'texts': [],
    'last_result_bgr': None,
    'source_name': '',
    'dpi': DEFAULT_DPI,
}


def _to_rgb(img_bgr):
    """统一出口：BGR → RGB，避免异常分支返回 BGR 导致预览偏色"""
    return cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)


def _font_path(font_name):
    """字体名 → 字体文件。带粗体后缀时先找同族粗体，再找常规体，最后回退第一个可用字体"""
    if not renderer.fonts:
        return None
    key = str(font_name or "").strip()
    if key in renderer.fonts:
        return renderer.fonts[key][0]
    stripped = re.sub(r"(\s*Bold|\s*粗体|\s*-Bold)$", "", key, flags=re.IGNORECASE).strip()
    if stripped in renderer.fonts:
        regular, bold = renderer.fonts[stripped]
        if stripped != key and bold != regular:
            return bold
        return regular
    return next(iter(renderer.fonts.values()))[0]


def load_image(file_obj):
    """用户上传文件后，读取并缩放到显示尺寸"""
    if file_obj is None:
        return None, empty_table(), "请先上传图片"

    file_path = file_obj.name if hasattr(file_obj, 'name') else file_obj
    try:
        pil_img = Image.open(file_path)
        dpi_tuple = pil_img.info.get("dpi") or (DEFAULT_DPI, DEFAULT_DPI)
        dpi = int(round(dpi_tuple[0])) or DEFAULT_DPI
        img_rgb = np.array(pil_img.convert('RGB'))
        img_bgr = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2BGR)
    except Exception as e:
        return None, empty_table(), f"读取图片失败: {e}"

    h, w = img_bgr.shape[:2]
    max_side = max(w, h)
    scale = 1.0
    if max_side > DISPLAY_MAX_SIDE:
        scale = DISPLAY_MAX_SIDE / max_side
        display = cv2.resize(img_bgr, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    else:
        display = img_bgr

    _state['orig_bgr'] = img_bgr
    _state['display_bgr'] = display
    _state['display_scale'] = scale
    _state['texts'] = []
    _state['last_result_bgr'] = None
    _state['source_name'] = os.path.splitext(os.path.basename(file_path))[0]
    _state['dpi'] = dpi

    size_mb = os.path.getsize(file_path) / 1024 / 1024
    msg = f"已加载: {w}x{h}px ({size_mb:.1f}MB)，DPI={dpi}"
    if scale != 1.0:
        msg += f"，显示缩放比例 {1/scale:.1f}x"
    # 换图必须清空操作表，否则旧区域会对应到新图
    return _to_rgb(display), empty_table(), msg


def do_detect():
    """在原图上做OCR，坐标还原"""
    orig = _state['orig_bgr']
    if orig is None:
        return None, empty_table(), "请先上传图片"
    if detector.ocr is None:
        return _to_rgb(_state["display_bgr"]), empty_table(), "OCR 模型未加载，请检查 rapidocr-onnxruntime 是否安装成功"

    h, w = orig.shape[:2]
    max_side = max(w, h)
    ocr_scale = 1.0
    if max_side > OCR_MAX_SIDE:
        ocr_scale = OCR_MAX_SIDE / max_side
        ocr_img = cv2.resize(orig, (int(w*ocr_scale), int(h*ocr_scale)), interpolation=cv2.INTER_AREA)
    else:
        ocr_img = orig

    texts_scaled = detector.detect(ocr_img)

    texts = []
    for t in texts_scaled:
        if ocr_scale != 1.0:
            t['x_min'] = int(t['x_min'] / ocr_scale)
            t['y_min'] = int(t['y_min'] / ocr_scale)
            t['x_max'] = int(t['x_max'] / ocr_scale)
            t['y_max'] = int(t['y_max'] / ocr_scale)
            t['w'] = int(t['w'] / ocr_scale)
            t['h'] = int(t['h'] / ocr_scale)
        texts.append(t)
    _state['texts'] = texts
    _state['last_result_bgr'] = None

    display = _state['display_bgr'].copy()
    disp_scale = _state['display_scale']
    for i, t in enumerate(texts):
        x1, y1 = int(t['x_min']*disp_scale), int(t['y_min']*disp_scale)
        x2, y2 = int(t['x_max']*disp_scale), int(t['y_max']*disp_scale)
        cv2.rectangle(display, (x1, y1), (x2, y2), (0, 255, 0), 2)
        cv2.putText(display, str(i), (x1+5, y1-5), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)

    df = pd.DataFrame({
        COL_ID: list(range(len(texts))),
        COL_TEXT: [t['text'] for t in texts],
        COL_BOX: [f"{t['w']}x{t['h']}" for t in texts],
        COL_ACTION: ["不改"] * len(texts),
        COL_NEW: [""] * len(texts),
        COL_SIZE: [0] * len(texts),
    })
    return _to_rgb(display), df, f"识别到 {len(texts)} 处文字"


def batch_set_action(df, action):
    df = normalize_table(df)
    if df is None or len(df) == 0:
        return df
    df = df.copy()
    df[COL_ACTION] = action
    return df


def find_replace(df, find_text, replace_text):
    """先按列向量算好结果再赋值，避免逐行赋值读到被污染的中间值"""
    df = normalize_table(df)
    if df is None or len(df) == 0 or not find_text:
        return df
    texts = df[COL_TEXT].astype(str)
    hit = texts.str.lower().str.contains(find_text.lower(), regex=False)
    replaced = texts.str.lower().str.replace(find_text.lower(), replace_text or "", regex=False)
    df.loc[hit, COL_NEW] = replaced[hit]
    df.loc[hit, COL_ACTION] = "替换"
    return df


def batch_set_new_text_to_orig(df):
    """一键把所有行的新文字填充为识别文字"""
    df = normalize_table(df)
    if df is None or len(df) == 0:
        return df
    df = df.copy()
    df[COL_NEW] = df[COL_TEXT]
    return df


def batch_set_font_size(df, size):
    """批量设置所有行的字号（空值/非数字时保持原值并提示）"""
    df = normalize_table(df)
    if df is None or len(df) == 0:
        return df, "请先检测文字"
    df = df.copy()
    try:
        value = int(float(size))
    except (TypeError, ValueError):
        return df, "统一字号请填数字，0 表示自动适配"
    value = max(0, value)
    df[COL_SIZE] = value
    hint = "自动适配" if value == 0 else f"{value}pt"
    return df, f"已把 {len(df)} 行字号设为 {hint}"


def _parse_font_size(value):
    """字号解析：空值/NaN/非数字按 0（自动），返回 (字号, 是否解析失败)"""
    if value is None:
        return 0, False
    if isinstance(value, float) and np.isnan(value):
        return 0, False
    s = str(value).strip()
    if s == "" or s.lower() == "nan":
        return 0, False
    try:
        return max(0, int(float(s))), False
    except ValueError:
        return 0, True


def do_generate(df, font_name, color_mode, custom_color):
    """在原图上生成，返回缩放后的显示图（批量渲染 + ROI 局部擦除）"""
    df = normalize_table(df)
    orig = _state['orig_bgr']
    if orig is None:
        return None, "请先上传图片并检测文字"
    if df is None or len(df) == 0:
        return _to_rgb(_state["display_bgr"]), "操作表是空的，请先点击「检测文字」"
    texts = _state['texts']
    if not texts:
        return _to_rgb(_state["display_bgr"]), "还没有检测到文字，请先点击「检测文字」"

    h, w = orig.shape[:2]
    dpi = _state.get('dpi') or DEFAULT_DPI
    by_id = {i: t for i, t in enumerate(texts)}

    mask = np.zeros((h, w), dtype=np.uint8)
    replaces = []
    bad_size_ids = []
    missing_ids = []
    for _, row in df.iterrows():
        try:
            region_id = int(row[COL_ID])
        except (KeyError, TypeError, ValueError):
            continue
        t = by_id.get(region_id)
        if t is None:
            missing_ids.append(region_id)
            continue
        action = str(row[COL_ACTION]).strip()
        new_text = str(row[COL_NEW]).strip()
        font_pt, bad = _parse_font_size(row.get(COL_SIZE))
        if bad:
            bad_size_ids.append(region_id)
        if action == "不改":
            continue
        # 只把原文字笔画写进 mask，保留框内其余背景纹理
        px1, py1 = max(0, t['x_min']), max(0, t['y_min'])
        px2, py2 = min(w, t['x_max']), min(h, t['y_max'])
        if px2 > px1 and py2 > py1:
            stroke = eraser.stroke_mask(orig[py1:py2, px1:px2], py2 - py1)
            mask[py1:py2, px1:px2] = np.maximum(mask[py1:py2, px1:px2], stroke)
        if action == "替换" and new_text:
            replaces.append({
                'text': new_text,
                'x1': t['x_min'], 'y1': t['y_min'],
                'x2': t['x_max'], 'y2': t['y_max'],
                'font_pt': font_pt,
            })

    # ROI 局部擦除（只在 mask 边界框内做 inpaint，比全图快很多）
    result = orig.copy()
    if mask.sum() > 0:
        ys, xs = np.where(mask > 0)
        x1, x2 = max(0, xs.min()-5), min(w, xs.max()+5)
        y1, y2 = max(0, ys.min()-5), min(h, ys.max()+5)
        roi_mask = mask[y1:y2, x1:x2]
        # 半径按擦除区域高度自适应：太小填不满，太大把周围纹理也涂糊
        radius = max(3, min(9, (y2 - y1) // 60 + 2))
        roi_erased = eraser.erase(result[y1:y2, x1:x2], roi_mask, radius=radius)
        result[y1:y2, x1:x2] = roi_erased

    # 批量渲染：一次性格式转换，避免 N 次全图拷贝
    if replaces:
        pil_img = Image.fromarray(cv2.cvtColor(result, cv2.COLOR_BGR2RGB))
        draw = ImageDraw.Draw(pil_img)
        fp = _font_path(font_name)

        for op in replaces:
            if color_mode == "custom":
                c = (custom_color or '#000000').lstrip('#')
                rgb = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
            else:
                bgr = renderer.extract_color(orig, op['x1'], op['y1'], op['x2'], op['y2'])
                rgb = (int(bgr[2]), int(bgr[1]), int(bgr[0]))

            bw, bh = op['x2']-op['x1'], op['y2']-op['y1']
            fs = pt_to_px(op['font_pt'], dpi) or max(10, int(bh * 0.75))

            try:
                font = ImageFont.truetype(fp, fs) if fp else ImageFont.load_default()
            except OSError:
                font = ImageFont.load_default()

            bb = draw.textbbox((0, 0), op['text'], font=font)
            tw, th = bb[2]-bb[0], bb[3]-bb[1]
            # 文字比原框宽时左对齐，避免整体挤出原区域；否则居中
            tx = op['x1'] if tw > bw else op['x1'] + (bw - tw) // 2
            ty = op['y1'] + (bh - th) // 2 - bb[1]
            draw.text((tx, ty), op['text'], fill=rgb, font=font)

        result = cv2.cvtColor(np.array(pil_img), cv2.COLOR_RGB2BGR)

    _state['last_result_bgr'] = result

    disp_scale = _state['display_scale']
    if disp_scale != 1.0:
        display_result = cv2.resize(result, (int(w*disp_scale), int(h*disp_scale)), interpolation=cv2.INTER_AREA)
    else:
        display_result = result

    msg = f"已处理完成：{len(replaces)} 处替换（字号按 {dpi}dpi 换算）"
    if bad_size_ids:
        msg += f"；区域 {bad_size_ids} 字号无法识别，已按自动适配"
    if missing_ids:
        msg += f"；区域 {missing_ids} 不在识别结果中，已跳过"
    return _to_rgb(display_result), msg


def save_hd_png():
    """保存高清原图尺寸的PNG，返回 (状态文本, 文件路径)"""
    result = _state['last_result_bgr']
    if result is None:
        return "没有可保存的结果，请先生成", None
    output_dir = OUTPUT_DIR
    os.makedirs(output_dir, exist_ok=True)
    # 原图名 + 时间戳，同一秒内连续导出自动补序号，不覆盖历史结果
    name = _state['source_name'] or 'image'
    stamp = time.strftime('%Y%m%d_%H%M%S')
    output_path = os.path.join(output_dir, f"{name}_edited_{stamp}.png")
    n = 1
    while os.path.exists(output_path):
        output_path = os.path.join(output_dir, f"{name}_edited_{stamp}_{n}.png")
        n += 1
    result_rgb = cv2.cvtColor(result, cv2.COLOR_BGR2RGB)
    Image.fromarray(result_rgb).save(output_path, "PNG", compress_level=0)
    h, w = result.shape[:2]
    return f"已保存高清PNG ({w}x{h}) 到: {output_path}", output_path


# ========== 界面 ==========
TABLE_HINT = ("### 文字操作表\n> 操作列填：`不改` / `替换` / `移除`　|　"
              "区域ID 对应预览图红字编号，请勿删除该列")

with gr.Blocks(title="图片改字工具 v6") as demo:
    gr.Markdown("# 图片改字工具 v6\n支持超大图片，只改文字，不动其他像素")

    with gr.Row():
        with gr.Column(scale=1):
            file_input = gr.File(label="上传图片（支持大文件）",
                                 file_types=[".png", ".jpg", ".jpeg", ".bmp", ".tiff"])
            load_btn = gr.Button("加载图片", variant="secondary")
            detect_btn = gr.Button("① 检测文字", variant="primary", size="lg")

            gr.Markdown("### 🛠 批量操作")
            with gr.Row():
                btn_all_keep = gr.Button("全部不改")
                btn_all_replace = gr.Button("全部替换")
                btn_all_remove = gr.Button("全部移除")

            gr.Markdown("**查找替换：**")
            with gr.Row():
                find_input = gr.Textbox(label="查找", placeholder="比如 Fibrosis")
                replace_input = gr.Textbox(label="替换为", placeholder="比如 纤维化")
            find_replace_btn = gr.Button("执行查找替换")

            gr.Markdown("**批量填充：**")
            with gr.Row():
                btn_fill_text = gr.Button("新文字 = 识别文字")
            with gr.Row():
                batch_size_input = gr.Number(label="统一字号(pt)", value=0, precision=0)
                btn_apply_size = gr.Button("应用统一字号")
            gr.Markdown("> 字号列：0 = 自动适配，填数字 = 固定字号(pt)，按图片 DPI 换算")

            gr.Markdown("### 🎨 字体样式")
            with gr.Row():
                font_dd = gr.Dropdown(label="字体", choices=font_choices,
                                      value=font_choices[0] if font_choices else "微软雅黑")
                color_mode = gr.Radio(label="颜色", choices=["auto", "custom"], value="auto")
                custom_color = gr.ColorPicker(label="自定义", value="#000000", visible=False)

            generate_btn = gr.Button("② 生成结果", variant="primary", size="lg")
            save_btn = gr.Button("💾 导出高清PNG", variant="secondary")

        with gr.Column(scale=1):
            preview_img = gr.Image(label="图片预览")
            gr.Markdown(TABLE_HINT)
            edit_table = gr.Dataframe(
                headers=HEADERS,
                # 全部按字符串接收：前端编辑后数值列可能变空，number 类型会变成 NaN 导致整列错位
                datatype=["str", "str", "str", "str", "str", "str"],
                # 固定高度：行数少时表格高度不再随编辑变化，避免看起来串行
                interactive=True, wrap=True, max_height=360,
                value=empty_table(),
                column_widths=["8%", "25%", "13%", "12%", "30%", "12%"],
            )
            status = gr.Textbox(label="状态", interactive=False)
            output_img = gr.Image(label="修改结果")
            out_file = gr.File(label="高清结果文件（点击下载）", interactive=False)

    color_mode.change(lambda m: gr.update(visible=(m == "custom")),
                      inputs=color_mode, outputs=custom_color)

    load_btn.click(load_image, inputs=file_input, outputs=[preview_img, edit_table, status])
    detect_btn.click(do_detect, outputs=[preview_img, edit_table, status])
    btn_all_keep.click(lambda df: batch_set_action(df, "不改"), inputs=edit_table, outputs=edit_table)
    btn_all_replace.click(lambda df: batch_set_action(df, "替换"), inputs=edit_table, outputs=edit_table)
    btn_all_remove.click(lambda df: batch_set_action(df, "移除"), inputs=edit_table, outputs=edit_table)
    find_replace_btn.click(find_replace, inputs=[edit_table, find_input, replace_input], outputs=edit_table)
    btn_fill_text.click(batch_set_new_text_to_orig, inputs=edit_table, outputs=edit_table)
    btn_apply_size.click(batch_set_font_size, inputs=[edit_table, batch_size_input],
                         outputs=[edit_table, status])
    generate_btn.click(do_generate,
        inputs=[edit_table, font_dd, color_mode, custom_color],
        outputs=[output_img, status])
    save_btn.click(save_hd_png, outputs=[status, out_file])


if __name__ == "__main__":
    # 云端部署通过 .env 注入 HOST=0.0.0.0；默认只监听本机，保持原有行为
    host = os.environ.get("HOST", "127.0.0.1")
    try:
        port = int(os.environ.get("PORT", "7860"))
    except ValueError:
        print(f"[WARN] PORT={os.environ.get('PORT')!r} 不是整数，回退 7860")
        port = 7860
    # allowed_paths：导出文件在 output 目录，需显式允许 Gradio 读取，否则下载会报 InvalidPathError
    demo.launch(server_name=host, server_port=port, share=False, max_file_size="500MB",
                allowed_paths=[OUTPUT_DIR])
