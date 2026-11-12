#!/usr/bin/env bash
# ============================================================
# 图片改字工具 v6 - Linux 一键部署脚本（Ubuntu / Debian）
# 用法: chmod +x install.sh && ./install.sh
#
# 部署包自包含，整个 deploy/linux 目录上传到服务器即可运行。
#
# 做的事:
#   1. 检查/安装 Python 3.10+（gradio 6 的要求）
#   2. 在部署包目录创建 venv 虚拟环境
#   3. 安装 requirements.txt 依赖（清华源，失败自动回退官方源）
#   4. 安装 OpenCV 运行时库（libGL）与中文字体 Noto CJK
#   5. 写入云端监听配置 .env，创建 output 目录并做一次依赖自检
#
# 目录约定:
#   deploy/linux/venv/bin/python          本脚本创建
#   deploy/linux/image_text_editor.py     主程序入口
#   deploy/linux/output/                  导出图片
#   deploy/linux/.env                     监听地址/端口
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
ENTRY="${PROJECT_ROOT}/image_text_editor.py"
VENV_DIR="${PROJECT_ROOT}/venv"
REQ_FILE="${PROJECT_ROOT}/requirements.txt"
ENV_FILE="${PROJECT_ROOT}/.env"

# 复用已有 .env 中的监听配置；首次部署默认对云服务器外网开放
if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${ENV_FILE}"
    set +a
fi
PORT="${PORT:-7860}"

if [ -t 1 ]; then
    C_OK="$(printf "\033[32m")"; C_ERR="$(printf "\033[31m")"
    C_WARN="$(printf "\033[33m")"; C_INFO="$(printf "\033[36m")"; C_END="$(printf "\033[0m")"
else
    C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_END=""
fi
info()  { printf "%s[INFO]%s  %s\n" "${C_INFO}" "${C_END}" "$*"; }
ok()    { printf "%s[ OK ]%s  %s\n" "${C_OK}" "${C_END}" "$*"; }
warn()  { printf "%s[WARN]%s  %s\n" "${C_WARN}" "${C_END}" "$*"; }
error() { printf "%s[FAIL]%s  %s\n" "${C_ERR}" "${C_END}" "$*" >&2; }

case "${PORT}" in
    ""|*[!0-9]*) warn "PORT=${PORT} 非法，回退 7860"; PORT=7860 ;;
esac

# root 运行时不要加 sudo
SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

# 部署包必须完整；缺文件时直接报错，避免装完依赖才发现无法启动
for f in image_text_editor.py manage.sh start.sh stop.sh restart.sh status.sh logs.sh requirements.txt; do
    if [ ! -f "${PROJECT_ROOT}/${f}" ]; then
        error "部署包缺少 ${f}"
        error "请重新上传完整的 deploy/linux 目录"
        exit 1
    fi
done

echo "=========================================="
echo "  图片改字工具 v6 - Linux 部署"
echo "=========================================="
echo

# ---------- 1. Python 3.10+ ----------
info "[1/5] 检查 Python 3.10+ ..."
PY_BIN=""
if command -v python3 >/dev/null 2>&1 && python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
    PY_BIN="$(command -v python3)"
else
    warn "未找到 Python 3.10+，尝试用 apt 安装 ..."
    $SUDO apt-get update
    $SUDO apt-get install -y python3 python3-pip python3-venv python3-dev || true
    for cand in python3.12 python3.11 python3.10 python3; do
        if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
            PY_BIN="$(command -v "$cand")"
            break
        fi
    done
fi
if [ -z "${PY_BIN}" ]; then
    error "Python 3.10+ 不可用。Ubuntu 20.04 及更早版本请先加 deadsnakes 源："
    echo "  $SUDO apt-get install -y software-properties-common"
    echo "  $SUDO add-apt-repository -y ppa:deadsnakes/ppa"
    echo "  $SUDO apt-get install -y python3.10 python3.10-venv python3.10-dev"
    exit 1
fi
info "解释器: $PY_BIN"
"$PY_BIN" --version

# ---------- 2. venv ----------
info "[2/5] 创建虚拟环境 ${VENV_DIR} ..."
if [ ! -x "${VENV_DIR}/bin/python" ]; then
    if ! "$PY_BIN" -m venv "${VENV_DIR}" 2>/dev/null; then
        warn "缺少 venv 模块，补充安装 ..."
        PY_SHORT="$("${PY_BIN}" -c "import sys; print(str(sys.version_info[0]) + '.' + str(sys.version_info[1]))")"
        $SUDO apt-get install -y python3-venv "python${PY_SHORT}-venv" || true
        "$PY_BIN" -m venv "${VENV_DIR}"
    fi
fi
VENV_PY="${VENV_DIR}/bin/python"
ok "虚拟环境就绪"

# ---------- 3. 依赖 ----------
info "[3/5] 安装 Python 依赖 ..."
"$VENV_PY" -m pip install --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
if ! "$VENV_PY" -m pip install -r "$REQ_FILE" -i https://pypi.tuna.tsinghua.edu.cn/simple; then
    warn "清华源失败，改用官方 PyPI 重试 ..."
    "$VENV_PY" -m pip install -r "$REQ_FILE"
fi
ok "依赖安装完成"

# ---------- 4. 运行时库与中文字体 ----------
info "[4/5] 安装 OpenCV 运行时库与中文字体 ..."
# opencv-python 在无桌面的 Linux 上依赖 libGL/libglib，缺失会导致 import cv2 失败
$SUDO apt-get update || warn "apt-get update 失败，继续尝试安装"
$SUDO apt-get install -y libgl1 libglib2.0-0 \
    || $SUDO apt-get install -y libgl1-mesa-glx libglib2.0-0 \
    || warn "libGL 安装失败，如 import cv2 报错请手动安装 libgl1 libglib2.0-0"

# 不因"系统已有任意中文字体"跳过：主程序需要 Noto/文泉驿/DejaVu 这些明确路径
info "安装 Noto CJK、文泉驿与 DejaVu 字体 ..."
$SUDO apt-get install -y fonts-noto-cjk fonts-dejavu-core || warn "Noto CJK 字体安装失败，中文可能显示为方块"
$SUDO apt-get install -y fonts-wqy-zenhei || true
command -v fc-cache >/dev/null 2>&1 && $SUDO fc-cache -f >/dev/null 2>&1 || true
fc-list :lang=zh 2>/dev/null | head -5 || true

# 主程序优先读取 /usr/share/fonts/opentype/noto；部分发行版是 OTF 或其它目录，统一补软链接
NOTO_DIR="/usr/share/fonts/opentype/noto"
$SUDO mkdir -p "${NOTO_DIR}"
link_noto_font() {
    local target="$1" pattern="$2" found
    if [ -e "${NOTO_DIR}/${target}" ]; then
        return 0
    fi
    # 优先使用同名 TTC，其次匹配任意 OTF/TTC 变体
    found="$(find /usr/share/fonts -type f -name "${target}" 2>/dev/null | head -1 || true)"
    if [ -z "${found}" ]; then
        found="$(find /usr/share/fonts -type f -iname "${pattern}" 2>/dev/null | head -1 || true)"
    fi
    if [ -n "${found}" ]; then
        $SUDO ln -sf "${found}" "${NOTO_DIR}/${target}"
        info "字体链接: ${found} -> ${NOTO_DIR}/${target}"
    fi
}
link_noto_font "NotoSansCJK-Regular.ttc" "NotoSansCJK*Regular*"
link_noto_font "NotoSansCJK-Bold.ttc" "NotoSansCJK*Bold*"
link_noto_font "NotoSerifCJK-Regular.ttc" "NotoSerifCJK*Regular*"
link_noto_font "NotoSerifCJK-Bold.ttc" "NotoSerifCJK*Bold*"
command -v fc-cache >/dev/null 2>&1 && $SUDO fc-cache -f >/dev/null 2>&1 || true

# 至少要有 2 个可用字体，避免页面字体下拉框只剩一项
FONT_COUNT=0
for p in \
    "${NOTO_DIR}/NotoSansCJK-Regular.ttc" \
    "/usr/share/fonts/google-noto/NotoSansCJKsc-Regular.otf" \
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc" \
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" \
    "/usr/share/fonts/dejavu/DejaVuSans.ttf" \
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"; do
    if [ -e "${p}" ]; then
        FONT_COUNT=$((FONT_COUNT + 1))
    fi
done
if [ "${FONT_COUNT}" -lt 2 ]; then
    warn "可用字体不足 2 个，页面字体下拉框可能只有一项；请检查 ${NOTO_DIR} 与 fc-list :lang=zh"
fi

# ---------- 5. 监听配置与自检 ----------
info "[5/5] 写入云端监听配置并自检 ..."
if [ ! -f "${ENV_FILE}" ]; then
    printf 'HOST=0.0.0.0\nPORT=%s\n' "${PORT}" > "${ENV_FILE}"
    ok "已写入 ${ENV_FILE}（HOST=0.0.0.0，允许外网访问）"
else
    info "保留已有配置 ${ENV_FILE}（如需调整监听地址/端口请直接编辑）"
fi

mkdir -p "${PROJECT_ROOT}/output"
"$VENV_PY" -c 'import sys, cv2, numpy, pandas, gradio, PIL, rapidocr_onnxruntime; print(sys.version.split()[0], gradio.__version__, cv2.__version__)'
ok "全部依赖可用"

chmod +x "${PROJECT_ROOT}/manage.sh" "${PROJECT_ROOT}/start.sh" "${PROJECT_ROOT}/stop.sh" \
    "${PROJECT_ROOT}/restart.sh" "${PROJECT_ROOT}/status.sh" "${PROJECT_ROOT}/logs.sh" 2>/dev/null \
    || warn "无法添加执行权限，请用 bash start.sh 启动"

echo
echo "=========================================="
echo "  部署完成"
echo "=========================================="
echo "  启动 : cd $PROJECT_ROOT && ./start.sh"
echo "  停止 : ./stop.sh"
echo "  重启 : ./restart.sh"
echo "  状态 : ./status.sh"
echo "  日志 : ./logs.sh"
echo "  访问 : http://服务器公网IP:${PORT}"
echo "  监听 : HOST=${HOST:-0.0.0.0} PORT=${PORT}（配置文件 ${ENV_FILE}）"
echo "  防火墙: $SUDO ufw allow ${PORT}/tcp"
echo
echo "  安全提醒: 服务无登录鉴权，请在云安全组限制来源 IP，不要直接暴露医学图片"
echo
