#!/usr/bin/env bash
#
# 图片改字工具 - 服务管理脚本（Linux / macOS / Git Bash）
# 用法: ./start.sh | ./stop.sh | ./restart.sh | ./manage.sh status
#
# 说明:
#   - start.sh / stop.sh / restart.sh 是指向本文件的软链接，脚本按被调用的名字分发
#   - 自动定位项目根目录，无需关心当前在哪个目录
#   - PID 文件 .run/image_text_editor.pid，日志 logs/image_text_editor.log
#   - 优先使用项目 venv 内的 python，没有则用系统 python3
#
set -uo pipefail

APP_NAME="image_text_editor"
ENTRY="src/image_text_editor.py"

# ---------- 路径 ----------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
RUN_DIR="${PROJECT_ROOT}/.run"
LOG_DIR="${PROJECT_ROOT}/logs"
PID_FILE="${RUN_DIR}/${APP_NAME}.pid"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"
VENV_PY="${PROJECT_ROOT}/venv/bin/python"

mkdir -p "${RUN_DIR}" "${LOG_DIR}"

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
    local port
    port="$(grep -oE "server_port=[0-9]+" "${PROJECT_ROOT}/${ENTRY}" 2>/dev/null | head -1 | cut -d= -f2)"
    echo "${port:-7860}"
}

# 选一个真正可用的解释器：Windows 上的 python3 常是应用商店占位符，必须验证能跑通
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

# 判断 PID 是否存活：Linux 看 /proc；Git Bash 的 ps 用 WINPID（第 4 列）匹配 Windows 进程号
is_running() {
    local pid="${1:-}"
    [ -n "${pid}" ] || return 1
    case "${pid}" in
        *[!0-9]*) return 1 ;;
    esac
    if [ -d "/proc/${pid}" ]; then
        return 0
    fi
    if ps -W 2>/dev/null | awk -v p="${pid}" '$4 == p {f=1} END {exit !f}'; then
        return 0
    fi
    builtin kill -0 "${pid}" 2>/dev/null
}

# 结束进程：Linux 用信号优雅退出；Windows/Git Bash 没有 SIGTERM，直接用 taskkill
terminate_pid() {
    local pid="$1" hard="${2:-no}"
    if command -v taskkill >/dev/null 2>&1 && [ ! -d "/proc/${pid}" ]; then
        taskkill //PID "${pid}" //F >/dev/null 2>&1
        return
    fi
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

# netstat 兜底：兼容 Windows(netstat -ano) 与 Linux(netstat -tlnp)
netstat_port_pid() {
    local port="$1"
    command -v netstat >/dev/null 2>&1 || return 0
    netstat -ano 2>/dev/null | grep -F ":$port " | grep -F "LISTENING" | head -1 | awk '{print $NF}'
}
# 端口监听进程：优先 lsof，其次 ss，最后 netstat
port_pid() {
    local port="$1" pid=""
    if command -v lsof >/dev/null 2>&1; then
        pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1)"
    elif command -v ss >/dev/null 2>&1; then
        pid="$(ss -lptn 2>/dev/null | grep -E ":$port[[:space:]]" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    fi
    if [ -z "$pid" ]; then
        pid="$(netstat_port_pid "$port")"
    fi
    echo "$pid"
}


# 判断某 PID 是否是本程序（命令行含入口文件名），用于决定端口占用者能否接管
port_pid_matches_app() {
    local pid="$1"
    [ -n "${pid}" ] || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr "\0" " " < "/proc/${pid}/cmdline" | grep -q "${ENTRY}" && return 0
    fi
    if command -v powershell >/dev/null 2>&1; then
        powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter 'ProcessId=${pid}').CommandLine" 2>/dev/null | grep -q "${ENTRY}" && return 0
    fi
    # 兜底：Python 进程（无法拿到命令行时按进程名近似判断）
    if ps -W 2>/dev/null | awk -v p="${pid}" '$4 == p' | grep -qi python; then
        return 0
    fi
    return 1
}

# ---------- start ----------
cmd_start() {
    local pid python port owner i answer
    pid="$(read_pid)"
    port="$(get_port)"

    # 已在运行（PID 文件有效）则直接返回，保证幂等
    if is_running "${pid}"; then
        warn "${APP_NAME} 已在运行 (PID ${pid})，无需重复启动"
        info "访问地址: http://127.0.0.1:${port}"
        return 0
    fi

    # PID 文件失效时，端口若已被本程序占用（例如上次异常退出），直接接管
    owner="$(port_pid "${port}")"
    if is_running "${owner}"; then
        if port_pid_matches_app "${owner}"; then
            echo "${owner}" >"${PID_FILE}"
            warn "检测到本程序已在运行 (PID ${owner})，已接管并写入 PID 文件"
            info "访问地址: http://127.0.0.1:${port}"
            return 0
        fi
        error "端口 ${port} 已被其他进程 ${owner} 占用，请先 ./stop.sh 或更换端口"
        return 1
    fi
    rm -f "${PID_FILE}"

    python="$(resolve_python)"
    if [ -z "${python}" ]; then
        error "未找到 Python 解释器，请先安装 python3 或执行 deploy/linux/install.sh"
        return 1
    fi
    if [ ! -f "${PROJECT_ROOT}/${ENTRY}" ]; then
        error "入口文件不存在: ${PROJECT_ROOT}/${ENTRY}"
        return 1
    fi

    info "启动 ${APP_NAME} ..."
    info "解释器: ${python}"
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
            info "访问地址: http://127.0.0.1:${port}"
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
        info "访问地址: http://127.0.0.1:${port}"
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
  ./manage.sh status      查看运行状态
  ./manage.sh log [N]     查看最近 N 行日志（默认 100）

日志: ${LOG_FILE}
PID : ${PID_FILE}
EOF
}

# ---------- 分发 ----------
ACTION="$(basename "$0" .sh)"
case "${ACTION}" in
    start|stop|restart|status|log) ;;
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
