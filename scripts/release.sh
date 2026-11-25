#!/usr/bin/env bash
# Builds everything people download into dist/.
#
# App signing needs DETOUR_KEY_PROPERTIES: the path of a file outside this
# repository with storeFile, storePassword, keyAlias and keyPassword.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DETOUR_KEY_PROPERTIES:?set it to your signing key.properties file}"

rm -rf dist
mkdir dist
for arch in amd64 arm64; do
  (cd server && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags='-s -w' -o "../dist/detour-server-linux-$arch" .)
done

(cd app && flutter build apk --release --split-per-abi)
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp "app/build/app/outputs/flutter-apk/app-$abi-release.apk" "dist/detour-android-$abi.apk"
done

(cd dist && sha256sum -- * > SHA256SUMS)
ls -lh dist
