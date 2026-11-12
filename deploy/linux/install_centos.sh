#!/usr/bin/env bash
# ============================================================
# 图片改字工具 v6 - CentOS 7 / 8 一键部署脚本
# 用法: chmod +x install_centos.sh && ./install_centos.sh
#
# 部署包自包含，整个 deploy/linux 目录上传到服务器即可运行。
#
# 重点：CentOS 7 自带 Python 3.6，而 gradio 6 要求 3.10+。
#   CentOS 8 / Stream : 走 dnf，python3 通常够用
#   CentOS 7          : 先试 SCL(rh-python311)，不行再源码编译 Python 3.10
#                       全程不覆盖系统 python（yum 依赖它）
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
PY_BUILD_DIR="${PROJECT_ROOT}/.pybuild"
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

SUDO=""; if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
PKG="yum"; if command -v dnf >/dev/null 2>&1; then PKG="dnf"; fi

# 部署包必须完整；缺文件时直接报错，避免装完依赖才发现无法启动
for f in image_text_editor.py manage.sh start.sh stop.sh restart.sh status.sh logs.sh requirements.txt; do
    if [ ! -f "${PROJECT_ROOT}/${f}" ]; then
        error "部署包缺少 ${f}"
        error "请重新上传完整的 deploy/linux 目录"
        exit 1
    fi
done

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
    # 源码包优先走国内镜像（官方 python.org 在国内下载极慢，常卡十几分钟）
    PY_TGZ="Python-3.10.14.tgz"
    # 已存在则先校验完整性，残缺包（如下载中断）必须重新下载
    if [ -f "${PY_TGZ}" ] && ! tar -tzf "${PY_TGZ}" >/dev/null 2>&1; then
        warn "已存在的 ${PY_TGZ} 不完整，删除后重新下载"
        rm -f "${PY_TGZ}"
    fi
    if [ ! -f "${PY_TGZ}" ]; then
        for mirror in \
            https://mirrors.huaweicloud.com/python/3.10.14/Python-3.10.14.tgz \
            https://mirrors.aliyun.com/python-release/source/Python-3.10.14.tgz \
            https://www.python.org/ftp/python/3.10.14/Python-3.10.14.tgz; do
            info "下载源码: ${mirror}"
            if wget -q --timeout=30 --tries=1 "${mirror}" -O "${PY_TGZ}"; then
                ok "下载完成"
                break
            fi
            warn "该源失败，尝试下一个"
            rm -f "${PY_TGZ}"
        done
    fi
    if [ ! -s "${PY_TGZ}" ]; then error "Python 源码下载失败，请手动下载到 ${PY_BUILD_DIR}"; exit 1; fi
    if ! tar -tzf "${PY_TGZ}" >/dev/null 2>&1; then error "Python 源码包损坏: ${PY_TGZ}"; exit 1; fi
    tar -xzf Python-3.10.14.tgz
    cd Python-3.10.14
    # 不启用 --enable-optimizations：CentOS 7 的 gcc 4.8.5 在 PGO 阶段会失败
    # (SystemError: compile returned NULL)，且该选项仅为性能优化，对本项目无感知
    # CentOS 7 自带 OpenSSL 1.0.2，Python 3.10 的 _ssl 需要 1.1.1+，故用 EPEL 的 openssl11
    # 不启用 --enable-optimizations：gcc 4.8.5 在 PGO 阶段会失败
    # openssl11 在 EPEL 源，首次部署需安装（独立目录，不覆盖系统 openssl）
    if [ ! -d /usr/include/openssl11 ]; then
        info "安装 openssl11（EPEL）..."
        $SUDO $PKG install -y openssl11 openssl11-devel >/dev/null 2>&1 \
            || warn "openssl11 安装失败，请确认 EPEL 源可用"
    fi
    if [ -d /usr/include/openssl11 ] && [ -f /usr/lib64/openssl11/libssl.so ]; then
        SSL_OPT="--with-openssl=/usr --with-openssl-rpath=auto"
        export CPATH="/usr/include/openssl11${CPATH:+:$CPATH}"
        export LIBRARY_PATH="/usr/lib64/openssl11${LIBRARY_PATH:+:$LIBRARY_PATH}"
        export LDFLAGS="-L/usr/lib64/openssl11 -Wl,-rpath,/usr/lib64/openssl11 ${LDFLAGS:-}"
        info "使用 openssl11: /usr/lib64/openssl11"
    else
        SSL_OPT=""
        warn "未找到 openssl11，_ssl 模块可能缺失"
    fi
    ./configure --prefix="${PY_BUILD_DIR}/python3.10" ${SSL_OPT} --with-ensurepip=install >/dev/null
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
"$VENV_PY" -m pip install --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
if ! "$VENV_PY" -m pip install -r "$REQ_FILE" -i https://pypi.tuna.tsinghua.edu.cn/simple; then
    warn "清华源失败，改用官方 PyPI 重试 ..."
    "$VENV_PY" -m pip install -r "$REQ_FILE"
fi
ok "依赖安装完成"

# ---------- 4. 运行时库与中文字体 ----------
info "[4/6] 安装 OpenCV 运行时库与中文字体 ..."
# opencv-python 在无桌面的 Linux 上依赖 libGL/libglib，缺失会导致 import cv2 失败
$SUDO $PKG install -y mesa-libGL libglvnd-glx >/dev/null 2>&1 \
    || $SUDO $PKG install -y mesa-libGL >/dev/null 2>&1 \
    || warn "libGL 安装失败，如 import cv2 报错请手动安装 mesa-libGL"

# 不因"系统已有任意中文字体"跳过：主程序需要 Noto/文泉驿/DejaVu 这些明确路径
info "安装 Noto CJK、文泉驿与 DejaVu 字体 ..."
$SUDO $PKG install -y google-noto-sans-cjk-ttc-fonts google-noto-serif-cjk-ttc-fonts >/dev/null 2>&1 \
    || $SUDO $PKG install -y google-noto-sans-cjk-fonts google-noto-serif-cjk-fonts >/dev/null 2>&1 \
    || warn "Noto CJK 字体安装失败，中文可能显示为方块"
# EPEL 没有 Noto Serif CJK（中文衬线），用文鼎明体/楷体补足宋体、楷体风格
$SUDO $PKG install -y wqy-zenhei-fonts >/dev/null 2>&1 || true
$SUDO $PKG install -y wqy-microhei-fonts >/dev/null 2>&1 || true
$SUDO $PKG install -y cjkuni-uming-fonts >/dev/null 2>&1 || true
$SUDO $PKG install -y cjkuni-ukai-fonts >/dev/null 2>&1 || true
$SUDO $PKG install -y dejavu-sans-fonts >/dev/null 2>&1 || true
# Liberation 是 Arial/Times New Roman/Courier New 的开源度量兼容替代品
$SUDO $PKG install -y liberation-sans-fonts liberation-serif-fonts liberation-mono-fonts >/dev/null 2>&1 \
    || $SUDO $PKG install -y liberation-sans-fonts >/dev/null 2>&1 || true
command -v fc-cache >/dev/null 2>&1 && $SUDO fc-cache -f >/dev/null 2>&1 || true
fc-list :lang=zh 2>/dev/null | head -5 || true

# 主程序优先读取 /usr/share/fonts/opentype/noto；CentOS 包可能是 OTF 或其它目录，统一补软链接
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
    "/usr/share/fonts/dejavu/DejaVuSans.ttf" \
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" \
    "/usr/share/fonts/wqy-zenhei/wqy-zenhei.ttc"; do
    if [ -e "${p}" ]; then
        FONT_COUNT=$((FONT_COUNT + 1))
    fi
done
if [ "${FONT_COUNT}" -lt 2 ]; then
    warn "可用字体不足 2 个，页面字体下拉框可能只有一项；请检查 ${NOTO_DIR} 与 fc-list :lang=zh"
fi

# ---------- 5. 防火墙 ----------
info "[5/6] 配置防火墙 ${PORT} 端口 ..."
if command -v firewall-cmd >/dev/null 2>&1; then
    $SUDO firewall-cmd --permanent --add-port="${PORT}"/tcp >/dev/null 2>&1 || true
    $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld 已放行 ${PORT}/tcp"
else
    warn "未检测到 firewalld，云服务器请在安全组放行 ${PORT}"
fi

# ---------- 6. 监听配置与自检 ----------
info "[6/6] 写入云端监听配置并自检 ..."
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
echo
echo "  安全提醒: 服务无登录鉴权，请在云安全组限制来源 IP，不要直接暴露医学图片"
echo