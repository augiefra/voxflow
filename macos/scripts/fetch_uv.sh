#!/bin/zsh
# Télécharge uv pour l'embarquer dans VoxFlow.app (Contents/Helpers/uv) : version
# épinglée, empreinte de l'archive vérifiée, licences prises au même tag.
# Affiche le dossier qui contient uv, LICENSE-MIT et LICENSE-APACHE.
set -euo pipefail

ROOT="${0:A:h:h}"
UV_VERSION="0.12.24"
UV_SHA256="0c4346de7abdb49495b393b9ec809fe387aa43e586be20fecb972216c1e71732"
DEST="$ROOT/.build/uv-$UV_VERSION"

if [[ ! -x "$DEST/uv" || ! -f "$DEST/LICENSE-MIT" || ! -f "$DEST/LICENSE-APACHE" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/uv.tar.gz" "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz"
  print -r -- "$UV_SHA256  $TMP/uv.tar.gz" | shasum -a 256 -c - >/dev/null \
    || { echo "Empreinte de uv $UV_VERSION inattendue : archive refusée." >&2; exit 1; }
  tar -xzf "$TMP/uv.tar.gz" -C "$TMP"
  mkdir -p "$DEST"
  cp "$TMP/uv-aarch64-apple-darwin/uv" "$DEST/uv" # uvx n'est pas embarqué
  for file in LICENSE-APACHE LICENSE-MIT; do
    curl -fsSL -o "$DEST/$file" "https://raw.githubusercontent.com/astral-sh/uv/$UV_VERSION/$file"
  done
fi
print -r -- "$DEST"
