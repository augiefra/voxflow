#!/bin/zsh
# Prépare une version distribuable de VoxFlow : signature Developer ID, notarisation
# Apple, DMG agrafé et appcast Sparkle signé. Ne publie rien : la mise en ligne passe
# par scripts/publish_release.sh.
# Usage : scripts/release.sh 0.2.0 [notes.txt]
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:?Usage : release.sh <version> [notes.txt]}"
NOTES="${2:-}"
[[ -f "$ROOT/release.env" ]] || { echo "Créer d'abord macos/release.env (modèle : release.env.example)." >&2; exit 1; }
source "$ROOT/release.env"
NOTARY_PROFILE="${NOTARY_PROFILE:-VoxFlowNotary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-voxflow}"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
DAEMON="${ROOT:h}/daemon"
DIST="$ROOT/dist/$VERSION"
APPCAST="$ROOT/release/appcast.xml"
APP="$ROOT/build/VoxFlow.app"
DMG="$DIST/VoxFlow-$VERSION.dmg"

step() { print -P "\n%B▸ $1%b"; }

notarize() {
  local file="$1" result state id
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  state="$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  id="$(print -r -- "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  if [[ "$state" != "Accepted" ]]; then
    echo "Notarisation refusée ($state). Journal Apple :" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
  echo "Notarisation acceptée ($id)"
}

step "Prérequis"
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
[[ -n "$IDENTITY" ]] || { echo "Certificat « Developer ID Application » absent du trousseau." >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
  || { echo "Profil de notarisation « $NOTARY_PROFILE » absent : voir README, section Distribution." >&2; exit 1; }
[[ -n "${APPCAST_URL:-}" && -n "${DOWNLOAD_URL_TEMPLATE:-}" ]] || { echo "APPCAST_URL ou DOWNLOAD_URL_TEMPLATE manquant." >&2; exit 1; }
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null \
  || { echo "Clé EdDSA Sparkle « $SPARKLE_ACCOUNT » absente du trousseau." >&2; exit 1; }
[[ ! -e "$DIST" ]] || { echo "$DIST existe déjà : version déjà préparée ?" >&2; exit 1; }
mkdir -p "$DIST" "${APPCAST:h}"
echo "Identité : $IDENTITY"

step "Crédits (licences des versions exactes de uv.lock)"
uv sync --frozen --project "$DAEMON" --python 3.12 --quiet
python3 "$ROOT/scripts/make_notices.py" "$DAEMON/.venv/lib/python3.12/site-packages" \
  "$SPARKLE_BIN/../LICENSE" "$("$ROOT/scripts/fetch_uv.sh")" "$ROOT/Resources/THIRD_PARTY_NOTICES.txt"

step "Construction et signature Developer ID"
"$ROOT/scripts/build_app.sh" --developer-id --version "$VERSION"

step "Notarisation de l'app"
ditto -c -k --keepParent "$APP" "$DIST/VoxFlow-notarize.zip"
notarize "$DIST/VoxFlow-notarize.zip"
rm "$DIST/VoxFlow-notarize.zip"
xcrun stapler staple "$APP"

step "DMG"
STAGING="$DIST/dmg"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/VoxFlow.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "VoxFlow $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

step "Contrôle Gatekeeper"
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

step "Appcast Sparkle"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"
URL="${DOWNLOAD_URL_TEMPLATE//\{version\}/$VERSION}"
python3 "$ROOT/scripts/update_appcast.py" "$APPCAST" "$VERSION" "$URL" "$SIGNATURE" ${NOTES:+"$NOTES"}
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$APPCAST" >/dev/null
cp "$APPCAST" "$DIST/appcast.xml"
[[ -n "$NOTES" ]] && cp "$NOTES" "$DIST/notes.txt"

step "Prêt, rien n'est publié"
echo "DMG     : $DMG"
echo "Appcast : $DIST/appcast.xml"
echo "Publier : scripts/publish_release.sh $VERSION"
