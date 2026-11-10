#!/usr/bin/env bash
# ============================================================
# 图片改字工具 v6 - Linux 一键部署脚本（Ubuntu / Debian）
# 用法: chmod +x install.sh && ./install.sh
#
# 做的事:
#   1. 检查/安装 Python 3.10+（gradio 6 的要求）
#   2. 在项目根目录创建 venv 虚拟环境
#   3. 安装 requirements.txt 依赖（清华源，失败自动回退官方源）
#   4. 安装中文字体 Noto CJK，否则渲染中文会变方块
#   5. 创建 output 目录并做一次依赖自检
#
# 目录约定（与项目根 manage.sh 一致）:
#   项目根/venv/bin/python          本脚本创建
#   项目根/src/image_text_editor.py 主程序入口
#   项目根/output/                  导出图片
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENTRY="${PROJECT_ROOT}/src/image_text_editor.py"
VENV_DIR="${PROJECT_ROOT}/venv"
REQ_FILE="${SCRIPT_DIR}/requirements.txt"

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

# root 运行时不要加 sudo
SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

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
        PY_SHORT="$(python3 -c "import sys; print(str(sys.version_info[0]) + "." + str(sys.version_info[1]))")"
        $SUDO apt-get install -y python3-venv "python${PY_SHORT}-venv" || true
        "$PY_BIN" -m venv "${VENV_DIR}"
    fi
fi
VENV_PY="${VENV_DIR}/bin/python"
ok "虚拟环境就绪"

# ---------- 3. 依赖 ----------
info "[3/5] 安装 Python 依赖 ..."
[ -f "$REQ_FILE" ] || { error "依赖清单不存在: $REQ_FILE"; exit 1; }
"$VENV_PY" -m pip install --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
if ! "$VENV_PY" -m pip install -r "$REQ_FILE" -i https://pypi.tuna.tsinghua.edu.cn/simple; then
    warn "清华源失败，改用官方 PyPI 重试 ..."
    "$VENV_PY" -m pip install -r "$REQ_FILE"
fi
ok "依赖安装完成"

# ---------- 4. 中文字体 ----------
info "[4/5] 检查中文字体 ..."
if command -v fc-list >/dev/null 2>&1 && [ -n "$(fc-list :lang=zh 2>/dev/null | head -1)" ]; then
    ok "系统已有中文字体"
else
    info "安装 Noto CJK 字体 ..."
    $SUDO apt-get install -y fonts-noto-cjk || warn "字体安装失败，中文可能显示为方块"
    command -v fc-cache >/dev/null 2>&1 && $SUDO fc-cache -f >/dev/null 2>&1 || true
fi
fc-list :lang=zh 2>/dev/null | head -5 || true

# ---------- 5. 自检 ----------
info "[5/5] 依赖自检 ..."
mkdir -p "$PROJECT_ROOT/output"
"$VENV_PY" -c 'import sys, cv2, numpy, pandas, gradio, PIL, rapidocr_onnxruntime; print(sys.version.split()[0], gradio.__version__, cv2.__version__)'
ok "全部依赖可用"

[ -f "$ENTRY" ] || warn "未找到入口文件 $ENTRY，请确认 src/ 已上传"
chmod +x "${PROJECT_ROOT}/manage.sh" "${PROJECT_ROOT}/start.sh" "${PROJECT_ROOT}/stop.sh" "${PROJECT_ROOT}/restart.sh" 2>/dev/null || true

echo
echo "=========================================="
echo "  部署完成"
echo "=========================================="
echo "  启动 : cd $PROJECT_ROOT && ./start.sh"
echo "  停止 : ./stop.sh"
echo "  状态 : ./manage.sh status"
echo "  日志 : ./manage.sh log"
echo "  访问 : http://服务器IP:7860"
echo "  防火墙: $SUDO ufw allow 7860/tcp"
echo
