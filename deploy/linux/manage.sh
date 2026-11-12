#!/usr/bin/env bash
#
# 图片改字工具 - Linux 部署包服务管理脚本
# 用法: ./start.sh | ./stop.sh | ./restart.sh | ./status.sh | ./logs.sh
#
# 说明:
#   - 本脚本与 image_text_editor.py 位于同一目录，整个 deploy/linux 可独立上传
#   - PID 文件 .run/image_text_editor.pid，日志 logs/image_text_editor.log
#   - 优先使用包内 venv/bin/python，没有则用系统 python3
#
set -uo pipefail

APP_NAME="image_text_editor"
ENTRY="image_text_editor.py"

# ---------- 路径 ----------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
RUN_DIR="${PROJECT_ROOT}/.run"
LOG_DIR="${PROJECT_ROOT}/logs"
OUTPUT_DIR="${PROJECT_ROOT}/output"
PID_FILE="${RUN_DIR}/${APP_NAME}.pid"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"
VENV_PY="${PROJECT_ROOT}/venv/bin/python"

# ---------- 监听配置 ----------
# .env 由 install.sh / install_centos.sh 生成；HOST=0.0.0.0 表示允许云端外网访问
if [ -f "${PROJECT_ROOT}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${PROJECT_ROOT}/.env"
    set +a
fi
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-}"

mkdir -p "${RUN_DIR}" "${LOG_DIR}" "${OUTPUT_DIR}"

# ---------- 输出（非终端自动降级为无色）----------
if [ -t 1 ]; then
    C_OK="$(printf "\033[32m")"
    C_ERR="$(printf "\033[31m")"
    C_WARN="$(printf "\033[33m")"
    C_INFO="$(printf "\033[36m")"
    C_END="$(printf "\033[0m")"
else
    C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_END=""
fi
info()  { printf "%s[INFO]%s  %s\n" "${C_INFO}" "${C_END}" "$*"; }
ok()    { printf "%s[ OK ]%s  %s\n" "${C_OK}" "${C_END}" "$*"; }
warn()  { printf "%s[WARN]%s  %s\n" "${C_WARN}" "${C_END}" "$*"; }
error() { printf "%s[FAIL]%s  %s\n" "${C_ERR}" "${C_END}" "$*" >&2; }

# ---------- 工具函数 ----------
get_port() {
    local port="${PORT:-}"
    case "${port}" in
        ""|*[!0-9]*) port="" ;;
    esac
    echo "${port:-7860}"
}

# 云端绑定 0.0.0.0 时不能提示 127.0.0.1，否则用户会误以为只能本机访问
access_hint() {
    local port="$1"
    if [ "${HOST}" = "0.0.0.0" ]; then
        echo "http://<服务器公网IP>:${port}"
    else
        echo "http://${HOST}:${port}"
    fi
}

is_usable_python() {
    [ -n "$1" ] && [ -x "$1" ] && "$1" -c "import sys" >/dev/null 2>&1
}

resolve_python() {
    local candidate
    if is_usable_python "${VENV_PY}"; then
        echo "${VENV_PY}"
        return
    fi
    for candidate in "${PYTHON_BIN:-}" "$(command -v python3 2>/dev/null)" "$(command -v python 2>/dev/null)"; do
        if is_usable_python "${candidate}"; then
            echo "${candidate}"
            return
        fi
    done
    echo ""
}

is_running() {
    local pid="${1:-}"
    [ -n "${pid}" ] || return 1
    case "${pid}" in
        *[!0-9]*) return 1 ;;
    esac
    if [ -d "/proc/${pid}" ]; then
        return 0
    fi
    builtin kill -0 "${pid}" 2>/dev/null
}

terminate_pid() {
    local pid="$1" hard="${2:-no}"
    if [ "${hard}" = "yes" ]; then
        kill -9 "-${pid}" 2>/dev/null || kill -9 "${pid}" 2>/dev/null
    else
        kill -TERM "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null
    fi
}

read_pid() {
    [ -f "${PID_FILE}" ] && tr -d "[:space:]" <"${PID_FILE}" 2>/dev/null
}

# PID 文件丢失时按命令行匹配兜底
find_pid_by_cmd() {
    pgrep -f "${ENTRY}" 2>/dev/null | head -1
}

# 端口监听进程：优先 lsof，其次 ss，最后 netstat
port_pid() {
    local port="$1" pid=""
    if command -v lsof >/dev/null 2>&1; then
        pid="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | head -1)"
    elif command -v ss >/dev/null 2>&1; then
        pid="$(ss -lptn 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    fi
    if [ -z "${pid}" ] && command -v netstat >/dev/null 2>&1; then
        pid="$(netstat -tlnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print $NF}' | head -1 | cut -d/ -f1)"
    fi
    echo "${pid}"
}

# 判断某 PID 是否是本程序，用于决定端口占用者能否接管
port_pid_matches_app() {
    local pid="$1"
    [ -n "${pid}" ] || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr "\0" " " < "/proc/${pid}/cmdline" | grep -q "${ENTRY}" && return 0
    fi
    return 1
}

# ---------- start ----------
cmd_start() {
    local pid python port owner i answer
    pid="$(read_pid)"
    port="$(get_port)"
    # 传给子进程：监听地址、端口、导出目录
    export HOST
    export PORT="${port}"
    export OUTPUT_DIR

    # 已在运行（PID 文件有效）则直接返回，保证幂等
    if is_running "${pid}"; then
        warn "${APP_NAME} 已在运行 (PID ${pid})，无需重复启动"
        info "访问地址: $(access_hint "${port}")"
        return 0
    fi

    # PID 文件失效时，端口若已被本程序占用（例如上次异常退出），直接接管
    owner="$(port_pid "${port}")"
    if is_running "${owner}"; then
        if port_pid_matches_app "${owner}"; then
            echo "${owner}" >"${PID_FILE}"
            warn "检测到本程序已在运行 (PID ${owner})，已接管并写入 PID 文件"
            info "访问地址: $(access_hint "${port}")"
            return 0
        fi
        error "端口 ${port} 已被其他进程 ${owner} 占用，请先 ./stop.sh 或修改 .env 中的 PORT"
        return 1
    fi
    rm -f "${PID_FILE}"

    python="$(resolve_python)"
    if [ -z "${python}" ]; then
        error "未找到 Python 解释器，请先执行 ./install.sh 或 ./install_centos.sh"
        return 1
    fi
    if [ ! -f "${PROJECT_ROOT}/${ENTRY}" ]; then
        error "入口文件不存在: ${PROJECT_ROOT}/${ENTRY}"
        return 1
    fi

    info "启动 ${APP_NAME} ..."
    info "解释器: ${python}"
    info "监听  : ${HOST}:${port}"
    info "日志  : ${LOG_FILE}"

    cd "${PROJECT_ROOT}" || return 1
    if command -v setsid >/dev/null 2>&1; then
        nohup setsid "${python}" -u "${ENTRY}" >>"${LOG_FILE}" 2>&1 &
    else
        nohup "${python}" -u "${ENTRY}" >>"${LOG_FILE}" 2>&1 &
    fi
    pid=$!
    echo "${pid}" >"${PID_FILE}"
    # 健康检查：最多等 60 秒直到端口就绪
    for i in $(seq 1 60); do
        if ! is_running "${pid}"; then
            error "启动失败，进程已退出，最近日志："
            tail -n 30 "${LOG_FILE}" >&2
            rm -f "${PID_FILE}"
            return 1
        fi
        answer="$(port_pid "${port}")"
        if [ -n "${answer}" ]; then
            echo "${answer}" >"${PID_FILE}"
            ok "${APP_NAME} 启动成功 (PID ${answer})，端口 ${port}"
            info "访问地址: $(access_hint "${port}")"
            return 0
        fi
        sleep 1
    done

    error "启动超时（60 秒内端口 ${port} 未就绪），请检查日志: ${LOG_FILE}"
    return 1
}

# ---------- stop ----------
cmd_stop() {
    local pid i port
    port="$(get_port)"
    pid="$(read_pid)"

    # PID 文件失效时依次兜底：命令行匹配 -> 端口占用者
    if ! is_running "${pid}"; then
        pid="$(find_pid_by_cmd)"
    fi
    if ! is_running "${pid}"; then
        pid="$(port_pid "${port}")"
    fi
    if [ -z "${pid}" ] || ! is_running "${pid}"; then
        warn "${APP_NAME} 未在运行"
        rm -f "${PID_FILE}"
        return 0
    fi

    info "停止 ${APP_NAME} (PID ${pid}) ..."
    # 进程组优先（setsid 启动时 pid 即进程组号），失败再杀单进程
    terminate_pid "${pid}"

    for i in $(seq 1 30); do
        if ! is_running "${pid}"; then
            ok "${APP_NAME} 已停止"
            rm -f "${PID_FILE}"
            return 0
        fi
        sleep 1
    done

    warn "优雅退出超时，强制结束"
    terminate_pid "${pid}" yes
    sleep 1
    if is_running "${pid}"; then
        error "进程 ${pid} 无法结束，请手动检查"
        return 1
    fi
    rm -f "${PID_FILE}"
    ok "${APP_NAME} 已强制停止"
    return 0
}

# ---------- status ----------
cmd_status() {
    local port pid owner
    port="$(get_port)"
    pid="$(read_pid)"
    owner="$(port_pid "${port}")"

    if is_running "${pid}"; then
        ok "${APP_NAME} 运行中 (PID ${pid})，端口 ${port}"
        info "访问地址: $(access_hint "${port}")"
        return 0
    fi
    if is_running "${owner}"; then
        warn "进程 ${owner} 正在监听端口 ${port}（可能是手动启动或上次异常退出）"
        info "如需接管，执行 ./stop.sh 再 ./start.sh"
        return 2
    fi
    warn "${APP_NAME} 未运行"
    return 3
}

# ---------- restart ----------
cmd_restart() {
    cmd_stop || return 1
    sleep 1
    cmd_start
}

# ---------- log ----------
cmd_log() {
    local n="${1:-100}"
    if [ ! -f "${LOG_FILE}" ]; then
        warn "日志文件不存在: ${LOG_FILE}"
        return 1
    fi
    info "最近 ${n} 行日志 (${LOG_FILE})："
    tail -n "${n}" "${LOG_FILE}"
}

usage() {
    cat <<EOF
${APP_NAME} 管理脚本

用法:
  ./start.sh              启动服务（后台常驻 + 健康检查）
  ./stop.sh               停止服务（优雅退出，30 秒后兜底强杀）
  ./restart.sh            重启服务
  ./status.sh             查看运行状态
  ./logs.sh [N]           查看最近 N 行日志（默认 100）
  ./manage.sh status      查看运行状态

日志: ${LOG_FILE}
PID : ${PID_FILE}

监听: ${HOST}:$(get_port)
     可在本目录 .env 中设置 HOST/PORT（云端部署用 HOST=0.0.0.0）
EOF
}

# ---------- 分发 ----------
ACTION="$(basename "$0" .sh)"
case "${ACTION}" in
    start|stop|restart|status|log) ;;
    logs) ACTION="log" ;;
    manage) ACTION="${1:-usage}"; shift || true ;;
    *) ACTION="usage" ;;
esac

case "${ACTION}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    log)     cmd_log "${1:-100}" ;;
    *)       usage ;;
esac
