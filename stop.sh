#!/usr/bin/env bash
# 包装脚本：实际逻辑在 manage.sh，便于不同平台（无符号链接权限）使用
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/manage.sh" stop "$@"
