#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="${ROOT_DIR}/apps/desktop"
APP_PATH="${DESKTOP_DIR}/build/macos/Build/Products/Release/oo_music.app"
DISTRIBUTION_DIR="${DESKTOP_DIR}/build/distribution"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "macOS release app does not exist: ${APP_PATH}" >&2
  exit 1
fi

VERSION="$(
  awk '/^version:[[:space:]]*/ { value=$2; sub(/\+.*/, "", value); print value; exit }' \
    "${DESKTOP_DIR}/pubspec.yaml"
)"
if [[ -z "${VERSION}" ]]; then
  echo "Unable to read application version from pubspec.yaml" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "${APP_PATH}"; then
  echo "macOS app signature verification failed" >&2
  exit 1
fi

ARCHITECTURES="$(lipo -archs "${APP_PATH}/Contents/MacOS/oo_music")"
if [[ "${ARCHITECTURES}" != *"arm64"* || "${ARCHITECTURES}" != *"x86_64"* ]]; then
  echo "Expected universal macOS binary, got: ${ARCHITECTURES}" >&2
  exit 1
fi

mkdir -p "${DISTRIBUTION_DIR}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oo-music-macos.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

VOLUME_DIR="${STAGING_DIR}/oo music"
mkdir -p "${VOLUME_DIR}"
ditto "${APP_PATH}" "${VOLUME_DIR}/oo_music.app"
ln -s /Applications "${VOLUME_DIR}/Applications"

cat >"${VOLUME_DIR}/README-macOS.txt" <<'EOF'
oo music - macOS 免费分发版

安装：
1. 将 oo_music.app 拖入右侧 Applications 文件夹。
2. 第一次启动若被 macOS 拦截，请打开：
   系统设置 -> 隐私与安全性。
3. 在被阻止的 oo music 条目旁点击“仍要打开”。
4. 输入本机密码并再次确认。

说明：
- 本版本使用 ad-hoc 签名，未使用付费 Apple Developer 公证。
- 不要关闭 Gatekeeper 全局保护，只需放行当前 App。
- 以后启动通常不会再出现同一拦截。
- 如需升级，请退出旧版本后，用新 App 替换 Applications 中的旧版本。

如果应用位于 Applications 且你信任本次下载来源，也可以执行：
xattr -dr com.apple.quarantine "/Applications/oo_music.app"
EOF

DMG_PATH="${DISTRIBUTION_DIR}/oo-music-${VERSION}-macos-universal.dmg"
rm -f "${DMG_PATH}" "${DMG_PATH}.sha256"
hdiutil create \
  -volname "oo music" \
  -srcfolder "${VOLUME_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"

cp "${VOLUME_DIR}/README-macOS.txt" "${DISTRIBUTION_DIR}/README-macOS.txt"
(
  cd "${DISTRIBUTION_DIR}"
  shasum -a 256 "$(basename "${DMG_PATH}")" >"$(basename "${DMG_PATH}").sha256"
)

echo "macOS DMG: ${DMG_PATH}"
echo "Architectures: ${ARCHITECTURES}"
echo "Note: this free distribution is not notarized; include README-macOS.txt."
