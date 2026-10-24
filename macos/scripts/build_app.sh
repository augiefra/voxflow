#!/bin/zsh
# Construit VoxFlow.app (release), y embarque le démon Python, uv et Sparkle, puis signe
# le bundle avec le runtime renforcé.
# Usage : scripts/build_app.sh [--install] [--developer-id] [--version X.Y.Z]
#   --install       copie l'app dans ~/Applications
#   --developer-id  signe avec « Developer ID Application » (distribution) au lieu
#                   d'« Apple Development » (usage local)
#   --version       fixe CFBundleShortVersionString et CFBundleVersion
set -euo pipefail

ROOT="${0:A:h:h}"
DAEMON_SRC="${ROOT:h}/daemon"
BUILD="$ROOT/build"
APP="$BUILD/VoxFlow.app"

INSTALL=0 DEVELOPER_ID=0 VERSION=""
while (( $# )); do
  case "$1" in
    --install) INSTALL=1 ;;
    --developer-id) DEVELOPER_ID=1 ;;
    --version) VERSION="$2"; shift ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

# Adresse du flux de mises à jour (Sparkle), hors du code : macos/release.env.
APPCAST_URL="${APPCAST_URL:-}"
[[ -f "$ROOT/release.env" ]] && source "$ROOT/release.env"

swift build --package-path "$ROOT" -c release --arch arm64
UV_DIR="$("$ROOT/scripts/fetch_uv.sh")"
BIN_PATH="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Helpers" "$APP/Contents/Resources/daemon"
cp "$BIN_PATH/VoxFlow" "$APP/Contents/MacOS/VoxFlow"
# uv installe Python et les paquets du démon au premier lancement : plus aucun prérequis.
cp "$UV_DIR/uv" "$APP/Contents/Helpers/uv"
ditto "$BIN_PATH/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$DAEMON_SRC/inference_daemon.py" "$DAEMON_SRC/model_store.py" "$DAEMON_SRC/pyproject.toml" "$DAEMON_SRC/uv.lock" \
  "$APP/Contents/Resources/daemon/"
# Textes français et anglais (l'app suit la langue du Mac).
for lang in en fr; do
  ditto "$ROOT/Resources/$lang.lproj" "$APP/Contents/Resources/$lang.lproj"
done
cp "$ROOT/Resources/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/"
cp "${ROOT:h}/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_URL" "$PLIST"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$PLIST"
fi

# Icône Icon Composer : Assets.car (Liquid Glass, macOS 26+) et VoxFlow.icns (macOS 14-15).
ICON_OUT="$BUILD/icon"
rm -rf "$ICON_OUT" && mkdir -p "$ICON_OUT"
xcrun actool "$ROOT/Resources/VoxFlow.icon" --compile "$ICON_OUT" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon VoxFlow \
  --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/VoxFlow.icns" "$APP/Contents/Resources/"

# Signature. Une identité stable garde les autorisations Accessibilité et Micro
# d'une compilation à l'autre ; une signature ad hoc oblige à les redonner.
if (( DEVELOPER_ID )); then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  [[ -n "$IDENTITY" ]] || { echo "Aucun certificat « Developer ID Application » dans le trousseau." >&2; exit 1; }
  TIMESTAMP=(--timestamp)
else
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
  IDENTITY="${IDENTITY:--}"
  TIMESTAMP=(--timestamp=none)
fi
sign() { codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY" "$@"; }

# Sparkle de l'intérieur vers l'extérieur, comme le recommande sa documentation.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --identifier com.ericcologni.voxflow.uv "$APP/Contents/Helpers/uv"
sign --entitlements "$ROOT/Resources/VoxFlow.entitlements" "$APP"
codesign --verify --strict --deep "$APP"
echo "Signé avec : $IDENTITY (runtime renforcé)"
echo "Version : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
echo "Flux de mises à jour : ${APPCAST_URL:-non configuré (menu « Rechercher des mises à jour » masqué)}"
echo "App : $APP"

if (( INSTALL )); then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/VoxFlow.app"
  ditto "$APP" "$HOME/Applications/VoxFlow.app"
  echo "Installée : $HOME/Applications/VoxFlow.app"
fi
