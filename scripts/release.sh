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

server() { # name, GOARCH, GOARM
  (cd server && CGO_ENABLED=0 GOOS=linux GOARCH="$2" GOARM="${3:-}" \
    go build -trimpath -ldflags='-s -w' -o "../dist/detour-server-linux-$1" .)
}
server amd64 amd64
server arm64 arm64
server armv7 arm 7
server armv6 arm 6

apks=app/build/app/outputs/flutter-apk
(cd app && flutter build apk --release --split-per-abi)
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp "$apks/app-$abi-release.apk" "dist/detour-android-$abi.apk"
done
# Has a lower version code than the split builds, so it can't update them.
(cd app && flutter build apk --release)
cp "$apks/app-release.apk" dist/detour-android-universal.apk

(cd dist && sha256sum -- * > SHA256SUMS)
ls -lh dist
