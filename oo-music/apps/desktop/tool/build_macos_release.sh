#!/usr/bin/env bash

set -euo pipefail

# 每次构建前移除旧 macOS 客户端，确保项目内只保留本次产物。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

# 清理项目目录内的所有旧客户端，避免多个 oo_music.app 同时残留。
find "${ROOT_DIR}" -type d -name "oo_music.app" -prune -exec rm -rf {} + 2>/dev/null || true

cd "${ROOT_DIR}"
build_arguments=(build macos --release --no-pub)
if [[ -n "${API_BASE_URL:-}" ]]; then
  build_arguments+=("--dart-define=API_BASE_URL=${API_BASE_URL}")
fi
"${FLUTTER_BIN}" "${build_arguments[@]}"

APP_PATH="${ROOT_DIR}/build/macos/Build/Products/Release/oo_music.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "macOS 构建产物不存在: ${APP_PATH}" >&2
  exit 1
fi

APP_COUNT="$(find "${ROOT_DIR}" -type d -name "oo_music.app" -print | wc -l | tr -d ' ')"
if [[ "${APP_COUNT}" != "1" ]]; then
  echo "客户端产物数量异常：应为 1 个，实际为 ${APP_COUNT} 个" >&2
  find "${ROOT_DIR}" -type d -name "oo_music.app" -print >&2
  exit 1
fi

echo "macOS 客户端: ${APP_PATH}"
