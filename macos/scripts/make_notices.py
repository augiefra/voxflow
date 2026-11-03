#!/usr/bin/env python3
"""Génère Resources/THIRD_PARTY_NOTICES.txt : modèles, Sparkle, uv (et ses crates Rust),
Python et paquets du démon.

Les licences des paquets sont lues dans les dist-info de l'environnement du démon
(installé depuis uv.lock), donc toujours celles des versions réellement utilisées.
Usage : make_notices.py <site-packages> <Sparkle LICENSE> <dossier uv (scripts/fetch_uv.sh)> <sortie>
"""
import email
import sys
from pathlib import Path

RULE = "=" * 78

PYTHON = """\
PYTHON 3.12 (téléchargé par uv au premier lancement, non inclus dans l'app)

CPython, Python Software Foundation
  https://www.python.org
  Licence : Python Software Foundation License Version 2 (https://docs.python.org/3/license.html)
Distribution python-build-standalone, Astral
  https://github.com/astral-sh/python-build-standalone
  Licence : Mozilla Public License 2.0 ; les composants inclus gardent leur propre licence
"""

MODELS = """\
MODÈLES (téléchargés depuis Hugging Face au premier lancement, non inclus dans l'app)

Parakeet TDT 0.6B v3, NVIDIA
  https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
  Conversion MLX : https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/tree/ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15
  Licence : CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/ ; texte complet ci-après)
  Modifications : poids convertis au format MLX par mlx-community.

Whisper large-v3-turbo, OpenAI (moteur ASR optionnel)
  https://huggingface.co/openai/whisper-large-v3-turbo
  Conversion MLX : https://huggingface.co/mlx-community/whisper-large-v3-turbo-asr-fp16
  Licence : MIT

  Copyright (c) 2022 OpenAI

  Permission is hereby granted, free of charge, to any person obtaining a copy of this software
  and associated documentation files (the "Software"), to deal in the Software without
  restriction, including without limitation the rights to use, copy, modify, merge, publish,
  distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
  Software is furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all copies or
  substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
  BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Voxtral Mini 4B Realtime (2602), Mistral AI (moteur ASR optionnel)
  https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602
  Conversion 4 bits MLX : https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit
  Licence : Apache License 2.0 (texte complet en fin de fichier)

Qwen3.5-4B, équipe Qwen (Alibaba Cloud)
  https://huggingface.co/Qwen/Qwen3.5-4B
  Conversion 4 bits MLX : https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit
  Licence : Apache License 2.0 (texte complet en fin de fichier)
"""


def package_entries(site_packages: Path) -> list[str]:
    entries = []
    for dist in sorted(site_packages.glob("*.dist-info"), key=lambda p: p.name.lower()):
        meta = email.message_from_string((dist / "METADATA").read_text(errors="replace"))
        name, version = meta["Name"], meta["Version"]
        license_name = meta.get("License-Expression") or ""
        if not license_name:
            classifiers = [c.split("::")[-1].strip() for c in meta.get_all("Classifier") or [] if c.startswith("License")]
            license_name = ", ".join(classifiers) or (meta.get("License") or "").splitlines()[0][:80]
        url = meta.get("Home-page") or next(
            (u.split(",", 1)[1].strip() for u in meta.get_all("Project-URL") or [] if "," in u), "")
        texts = sorted(p for p in (dist / "licenses").rglob("*") if p.is_file()) if (dist / "licenses").exists() else []
        if not texts:
            texts = sorted(p for p in dist.iterdir() if p.name.upper().startswith(("LICENSE", "LICENCE", "COPYING")))
        body = "\n\n".join(t.read_text(errors="replace").strip() for t in texts)
        entries.append(f"{name} {version}\n  Licence : {license_name or 'voir le projet'}\n  {url}\n\n{body or '(texte de licence non fourni par le paquet)'}")
    return entries


def main() -> None:
    site_packages, sparkle_license, uv_dir, output = map(Path, sys.argv[1:5])
    licenses = Path(__file__).resolve().parent.parent / "Resources/licenses"
    cc_by = (licenses / "CC-BY-4.0.txt").read_text().strip()
    apache = (licenses / "Apache-2.0.txt").read_text().strip()
    crates = licenses / "uv-crates.txt"
    parts = [
        "VoxFlow — composants tiers et licences",
        "VoxFlow s'appuie sur les travaux suivants. Merci à leurs auteurs.",
        RULE, MODELS,
        RULE, "CREATIVE COMMONS ATTRIBUTION 4.0 INTERNATIONAL (Parakeet TDT 0.6B v3)\n\n"
              + cc_by,
        RULE, "SPARKLE (inclus dans l'app : mises à jour automatiques)\nhttps://sparkle-project.org\n\n"
              + sparkle_license.read_text().strip(),
        RULE, "UV, Astral (inclus dans l'app : installe Python et les paquets du démon)\n"
              "https://github.com/astral-sh/uv\nLicence : MIT ou Apache 2.0, au choix (texte Apache en fin de fichier)\n\n"
              + (uv_dir / "LICENSE-MIT").read_text().strip(),
        RULE, "UV — BIBLIOTHÈQUES RUST LIÉES DANS LE BINAIRE (scripts/uv_crate_notices.py)\n\n"
              + crates.read_text().strip(),
        RULE, PYTHON,
        RULE, "PAQUETS PYTHON DU DÉMON (installés par uv au premier lancement, non inclus dans l'app)",
    ]
    for entry in package_entries(site_packages):
        parts += ["-" * 78, entry]
    parts += [RULE, "APACHE LICENSE 2.0 (Voxtral, Qwen3.5, uv et paquets sous Apache 2.0)\n\n" + apache]
    output.write_text("\n\n".join(parts) + "\n")
    print(f"{output} : {output.stat().st_size // 1024} Ko")


if __name__ == "__main__":
    main()
