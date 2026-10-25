#!/bin/zsh
# 建置 PhoneCentre.app
#   scripts/build.sh            release 建置並輸出到 build/PhoneCentre.app
#   scripts/build.sh --install  另外複製到 /Applications
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

SCRCPY_VERSION="3.3.4"
SCRCPY_SHA256="8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e"
SCRCPY_SERVER="ThirdParty/scrcpy/scrcpy-server"
HELPER_JAR="Resources/phonecentre-helper.jar"
APP="build/PhoneCentre.app"

# ---- 1. scrcpy-server（Apache-2.0，官方 release 檔，檢查 SHA256）----
if [[ ! -f "$SCRCPY_SERVER" ]] || [[ "$(shasum -a 256 "$SCRCPY_SERVER" | cut -d' ' -f1)" != "$SCRCPY_SHA256" ]]; then
  echo "==> 下載 scrcpy-server v$SCRCPY_VERSION"
  mkdir -p "${SCRCPY_SERVER:h}"
  curl -fL -o "$SCRCPY_SERVER" \
    "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VERSION/scrcpy-server-v$SCRCPY_VERSION"
  [[ "$(shasum -a 256 "$SCRCPY_SERVER" | cut -d' ' -f1)" == "$SCRCPY_SHA256" ]] || { echo "scrcpy-server SHA256 不符"; exit 1; }
fi

# ---- 2. Android 輔助程式（有 SDK 時才重建，否則使用已提交的 jar）----
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [[ -d "$SDK/build-tools" ]] && [[ ! -f "$HELPER_JAR" || -n "$(find AndroidHelper/src -newer "$HELPER_JAR" -name '*.java')" ]]; then
  echo "==> 建置 Android 輔助程式"
  BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
  PLATFORM="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -1)"
  JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null || echo "/Applications/Android Studio.app/Contents/jbr/Contents/Home")}"
  export JAVA_HOME
  TMP="$(mktemp -d)"
  "$JAVA_HOME/bin/javac" -source 8 -target 8 -nowarn -Xlint:-options \
    -bootclasspath "$PLATFORM/android.jar" -d "$TMP/classes" $(find AndroidHelper/src -name '*.java')
  "$BT/d8" --min-api 26 --lib "$PLATFORM/android.jar" --output "$TMP" $(find "$TMP/classes" -name '*.class')
  (cd "$TMP" && zip -q helper.jar classes.dex)
  mkdir -p Resources && cp "$TMP/helper.jar" "$HELPER_JAR"
  rm -rf "$TMP"
fi

# ---- 3. App 圖示 ----
if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "==> 產生 App 圖示"
  swift scripts/make_icon.swift Resources/AppIcon.icns
fi

# ---- 4. Swift 編譯 ----
echo "==> swift build"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/PhoneCentre"

# ---- 5. 組裝 .app ----
echo "==> 組裝 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhoneCentre"
# SwiftPM 會把執行檔標成「用 macOS 14 SDK 建置」，系統就會沿用舊外觀；改標成目前的 SDK，才會套用新版 Liquid Glass 外觀
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace -output "$APP/Contents/MacOS/PhoneCentre" "$APP/Contents/MacOS/PhoneCentre"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$HELPER_JAR" "$APP/Contents/Resources/"
cp "$SCRCPY_SERVER" "$APP/Contents/Resources/scrcpy-server"
cp ThirdParty/NOTICE.md "$APP/Contents/Resources/"
cp -R ThirdParty/licenses "$APP/Contents/Resources/"
# 簽章：優先用 Apple Development 憑證（簽章固定，重新編譯後不必重新允許區域網路／鑰匙圈），
# 可用 PHONECENTRE_SIGN 指定，找不到就用 ad-hoc
SIGN="${PHONECENTRE_SIGN:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | awk '{print $2}')}"
codesign --force --deep -s "${SIGN:--}" "$APP"
echo "==> 簽章：${SIGN:-ad-hoc}"
echo "==> 完成：$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x PhoneCentre 2>/dev/null || true
  rm -rf /Applications/PhoneCentre.app
  cp -R "$APP" /Applications/
  echo "==> 已安裝到 /Applications/PhoneCentre.app"
fi
