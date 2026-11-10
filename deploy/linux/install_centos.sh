#!/usr/bin/env bash
# ============================================================
# 图片改字工具 v6 - CentOS 7 / 8 一键部署脚本
# 用法: chmod +x install_centos.sh && ./install_centos.sh
#
# 重点：CentOS 7 自带 Python 3.6，而 gradio 6 要求 3.10+。
#   CentOS 8 / Stream : 走 dnf，python3 通常够用
#   CentOS 7          : 先试 SCL(rh-python311)，不行再源码编译 Python 3.10
#                       全程不覆盖系统 python（yum 依赖它）
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
PY_BUILD_DIR="${PROJECT_ROOT}/.pybuild"

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

SUDO=""; if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
PKG="yum"; if command -v dnf >/dev/null 2>&1; then PKG="dnf"; fi

echo "=========================================="
echo "  图片改字工具 v6 - CentOS 部署"
echo "=========================================="
echo
info "包管理器: $PKG"

# ---------- 1. 找到 >= 3.10 的 Python ----------
info "[1/6] 检查 Python 3.10+ ..."
pick_python() {
    local c
    for c in python3.12 python3.11 python3.10 python3; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
            command -v "$c"
            return 0
        fi
    done
    return 1
}
PY_BIN="$(pick_python || true)"

if [ -z "$PY_BIN" ]; then
    info "尝试通过 SCL 安装 Python 3.11 ..."
    $SUDO $PKG install -y centos-release-scl >/dev/null 2>&1 || true
    $SUDO $PKG install -y rh-python311 rh-python311-python-devel >/dev/null 2>&1 || true
    if [ -x "/opt/rh/rh-python311/root/usr/bin/python3.11" ]; then
        PY_BIN="/opt/rh/rh-python311/root/usr/bin/python3.11"
    fi
fi

if [ -z "$PY_BIN" ]; then
    info "源码编译 Python 3.10.14 到 ${PY_BUILD_DIR}（不覆盖系统 python，约 10-20 分钟）..."
    $SUDO $PKG install -y gcc make openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel sqlite-devel readline-devel wget >/dev/null
    mkdir -p "${PY_BUILD_DIR}"
    cd "${PY_BUILD_DIR}"
    [ -f Python-3.10.14.tgz ] || wget -q https://www.python.org/ftp/python/3.10.14/Python-3.10.14.tgz
    tar -xzf Python-3.10.14.tgz
    cd Python-3.10.14
    ./configure --prefix="${PY_BUILD_DIR}/python3.10" --enable-optimizations --with-ensurepip=install >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
    PY_BIN="${PY_BUILD_DIR}/python3.10/bin/python3.10"
    cd "$PROJECT_ROOT"
fi

if [ ! -x "${PY_BIN}" ]; then
    error "无法获得 Python 3.10+，请手动安装后重跑本脚本"
    exit 1
fi
info "解释器: ${PY_BIN}"
"$PY_BIN" --version

# ---------- 2. venv ----------
info "[2/6] 创建虚拟环境 ..."
if [ ! -x "${VENV_DIR}/bin/python" ]; then
    "$PY_BIN" -m venv "${VENV_DIR}" || { error "venv 创建失败，可能缺少 ensurepip/venv 模块"; exit 1; }
fi
VENV_PY="${VENV_DIR}/bin/python"
ok "虚拟环境就绪"

# ---------- 3. 依赖 ----------
info "[3/6] 安装 Python 依赖 ..."
[ -f "$REQ_FILE" ] || { error "依赖清单不存在: $REQ_FILE"; exit 1; }
"$VENV_PY" -m pip install --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
if ! "$VENV_PY" -m pip install -r "$REQ_FILE" -i https://pypi.tuna.tsinghua.edu.cn/simple; then
    warn "清华源失败，改用官方 PyPI 重试 ..."
    "$VENV_PY" -m pip install -r "$REQ_FILE"
fi
ok "依赖安装完成"

# ---------- 4. 中文字体 ----------
info "[4/6] 安装中文字体 ..."
if ! command -v fc-list >/dev/null 2>&1 || [ -z "$(fc-list :lang=zh 2>/dev/null | head -1)" ]; then
    $SUDO $PKG install -y google-noto-sans-cjk-fonts google-noto-serif-cjk-fonts >/dev/null 2>&1 || $SUDO $PKG install -y google-noto-sans-cjk-ttc-fonts >/dev/null 2>&1 || warn "字体安装失败，中文可能显示为方块"
    command -v fc-cache >/dev/null 2>&1 && $SUDO fc-cache -f >/dev/null 2>&1 || true
fi
fc-list :lang=zh 2>/dev/null | head -5 || true

# ---------- 5. 防火墙 ----------
info "[5/6] 配置防火墙 7860 端口 ..."
if command -v firewall-cmd >/dev/null 2>&1; then
    $SUDO firewall-cmd --permanent --add-port=7860/tcp >/dev/null 2>&1 || true
    $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld 已放行 7860/tcp"
else
    warn "未检测到 firewalld，云服务器请在安全组放行 7860"
fi

# ---------- 6. 自检 ----------
info "[6/6] 依赖自检 ..."
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
echo
