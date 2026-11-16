#!/usr/bin/env bash

set -euo pipefail

KEYSTORE_PATH="${1:-${HOME}/.oo-music/android/oo-music-release.jks}"
KEY_ALIAS="${ANDROID_KEY_ALIAS:-upload}"

if [[ -e "${KEYSTORE_PATH}" ]]; then
  echo "Refusing to overwrite existing keystore: ${KEYSTORE_PATH}" >&2
  exit 1
fi

mkdir -p "$(dirname "${KEYSTORE_PATH}")"
chmod 700 "$(dirname "${KEYSTORE_PATH}")"
KEYSTORE_DIR="$(cd "$(dirname "${KEYSTORE_PATH}")" && pwd)"
KEYSTORE_BASENAME="$(basename "${KEYSTORE_PATH}")"

if command -v keytool >/dev/null 2>&1 && keytool -help >/dev/null 2>&1; then
  KEYTOOL_MODE='host'
  KEYTOOL_PATH="${KEYSTORE_PATH}"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  KEYTOOL_MODE='docker'
  KEYTOOL_PATH="/keys/${KEYSTORE_BASENAME}"
else
  echo 'keytool was not found and Docker is unavailable.' >&2
  echo 'Install JDK 17, or start Docker so keytool can run in a temporary JDK container.' >&2
  exit 1
fi

if [[ -n "${ANDROID_KEYSTORE_PASSWORD:-}" ]]; then
  STORE_PASSWORD="${ANDROID_KEYSTORE_PASSWORD}"
else
  read -r -s -p 'Keystore password: ' STORE_PASSWORD
  echo
fi
if [[ ${#STORE_PASSWORD} -lt 6 ]]; then
  echo 'Keystore password must contain at least 6 characters.' >&2
  exit 1
fi

if [[ -n "${ANDROID_KEY_PASSWORD:-}" ]]; then
  KEY_PASSWORD="${ANDROID_KEY_PASSWORD}"
else
  read -r -s -p 'Key password (press Enter to use the keystore password): ' KEY_PASSWORD
  echo
fi
if [[ -z "${KEY_PASSWORD}" ]]; then
  KEY_PASSWORD="${STORE_PASSWORD}"
fi

run_keytool() {
  if [[ "${KEYTOOL_MODE}" == 'host' ]]; then
    keytool "$@"
  else
    docker run --rm -v "${KEYSTORE_DIR}:/keys" eclipse-temurin:17-jdk keytool "$@"
  fi
}

cat <<EOF
Creating the permanent Android release signing key.
Back up this file and both passwords. Every future APK update must use it.

Keystore: ${KEYSTORE_PATH}
Alias:    ${KEY_ALIAS}
EOF

run_keytool -genkeypair \
  -v \
  -storetype JKS \
  -keystore "${KEYTOOL_PATH}" \
  -alias "${KEY_ALIAS}" \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -dname "CN=oo music, OU=Client Distribution, O=oo music, L=Unknown, ST=Unknown, C=CN" \
  -storepass "${STORE_PASSWORD}" \
  -keypass "${KEY_PASSWORD}"

chmod 600 "${KEYSTORE_PATH}"
run_keytool -list \
  -keystore "${KEYTOOL_PATH}" \
  -storepass "${STORE_PASSWORD}" \
  -alias "${KEY_ALIAS}" >/dev/null

cat <<EOF

Keystore created successfully.

GitHub Actions secrets required:
  ANDROID_KEYSTORE_BASE64  = base64 of this JKS file
  ANDROID_KEYSTORE_PASSWORD
  ANDROID_KEY_ALIAS        = ${KEY_ALIAS}
  ANDROID_KEY_PASSWORD

macOS base64 command:
  base64 -i "${KEYSTORE_PATH}" | pbcopy

Linux base64 command:
  base64 -w0 "${KEYSTORE_PATH}"

Do not commit the keystore or passwords to Git.
EOF
