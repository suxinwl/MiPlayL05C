#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="${ROOT_DIR}/apps/desktop"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

: "${API_BASE_URL:?Set API_BASE_URL to the public HTTPS backend URL}"
: "${ANDROID_KEYSTORE_PATH:?Set ANDROID_KEYSTORE_PATH to the release keystore}"
: "${ANDROID_KEYSTORE_PASSWORD:?Set ANDROID_KEYSTORE_PASSWORD}"
: "${ANDROID_KEY_ALIAS:?Set ANDROID_KEY_ALIAS}"
: "${ANDROID_KEY_PASSWORD:?Set ANDROID_KEY_PASSWORD}"

if [[ ! -f "${ANDROID_KEYSTORE_PATH}" ]]; then
  echo "Android release keystore not found: ${ANDROID_KEYSTORE_PATH}" >&2
  exit 1
fi
if [[ ! "${API_BASE_URL}" =~ ^https:// ]] && \
   [[ ! "${API_BASE_URL}" =~ ^http://(127\.0\.0\.1|localhost|10\.0\.2\.2)(:([0-9]+))?(/|$) ]]; then
  echo "Release API_BASE_URL must use HTTPS (local loopback is allowed for tests)." >&2
  exit 1
fi

VERSION="$(
  awk '/^version:[[:space:]]*/ { value=$2; sub(/\+.*/, "", value); print value; exit }' \
    "${DESKTOP_DIR}/pubspec.yaml"
)"
if [[ -z "${VERSION}" ]]; then
  echo "Unable to read version from pubspec.yaml" >&2
  exit 1
fi

ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "${ANDROID_SDK}" || ! -d "${ANDROID_SDK}" ]]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT must point to the Android SDK" >&2
  exit 1
fi
APKSIGNER="$(
  find "${ANDROID_SDK}/build-tools" -type f -name apksigner |
    awk -F/ '{ print $(NF-1) "\t" $0 }' |
    sort -t. -k1,1n -k2,2n -k3,3n |
    tail -1 |
    cut -f2-
)"
if [[ -z "${APKSIGNER}" || ! -x "${APKSIGNER}" ]]; then
  echo "apksigner was not found in ${ANDROID_SDK}/build-tools" >&2
  exit 1
fi

cd "${DESKTOP_DIR}"
"${FLUTTER_BIN}" pub get
"${FLUTTER_BIN}" build apk \
  --release \
  "--dart-define=API_BASE_URL=${API_BASE_URL}"

APK_PATH="${DESKTOP_DIR}/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "${APK_PATH}" ]]; then
  echo "Flutter produced no release APK: ${APK_PATH}" >&2
  exit 1
fi

CERT_INFO="$("${APKSIGNER}" verify --verbose --print-certs "${APK_PATH}")"
printf '%s\n' "${CERT_INFO}"
if grep -qi 'CN=Android Debug' <<<"${CERT_INFO}"; then
  echo "Refusing to distribute an APK signed with the Android debug key." >&2
  exit 1
fi

DISTRIBUTION_DIR="${DESKTOP_DIR}/build/distribution"
mkdir -p "${DISTRIBUTION_DIR}"
ARTIFACT="oo-music-${VERSION}-android-universal.apk"
cp "${APK_PATH}" "${DISTRIBUTION_DIR}/${ARTIFACT}"
(
  cd "${DISTRIBUTION_DIR}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${ARTIFACT}" >"${ARTIFACT}.sha256"
  else
    shasum -a 256 "${ARTIFACT}" >"${ARTIFACT}.sha256"
  fi
)

cat >"${DISTRIBUTION_DIR}/README-Android.txt" <<'EOF'
oo music - Android 免费分发版

安装：
1. 打开 APK。
2. Android 会提示允许来自当前来源的安装，请按系统提示开启。
3. 返回安装界面并确认安装。
4. 若 Play Protect 提示未知应用，请确认下载来源可信后选择“仍要安装”。

说明：
- 这是使用固定 release key 签名的通用 APK。
- 不要用 debug key 重新签名，否则后续版本会无法覆盖升级。
- 以后升级时必须保留当前 APK 签名 key，并递增 versionCode。
- Android 不会允许普通官网 APK 静默安装；系统的未知来源确认无法移除。
EOF

echo "Android APK: ${DISTRIBUTION_DIR}/${ARTIFACT}"
