#!/bin/zsh
# Publie sur GitHub Releases une version préparée par release.sh : le DMG et l'appcast.
# Les apps installées voient la mise à jour au prochain contrôle Sparkle.
# Usage : scripts/publish_release.sh 0.2.0
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="${1:?Usage : publish_release.sh <version>}"
source "$ROOT/release.env"
DIST="$ROOT/dist/$VERSION"
DMG="$DIST/VoxFlow-$VERSION.dmg"
[[ -f "$DMG" && -f "$DIST/appcast.xml" ]] || { echo "Version $VERSION non préparée (release.sh)." >&2; exit 1; }
xcrun stapler validate "$DMG"

NOTES_ARGS=(--notes "VoxFlow $VERSION")
[[ -f "$DIST/notes.txt" ]] && NOTES_ARGS=(--notes-file "$DIST/notes.txt")
gh release create "v$VERSION" "$DMG" "$DIST/appcast.xml" --repo "$GITHUB_REPO" \
  --title "VoxFlow $VERSION" --latest "${NOTES_ARGS[@]}"
echo "Publiée. Flux : $APPCAST_URL"
