#!/usr/bin/env python3
"""Ajoute une version en tête de l'appcast Sparkle (l'historique est conservé).

Usage : update_appcast.py <appcast.xml> <version> <url du DMG> <attributs sign_update> [notes]
Les attributs sont la sortie de sign_update : sparkle:edSignature="…" length="…".
"""
import html
import re
import sys
from email.utils import formatdate
from pathlib import Path

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>VoxFlow</title>
    <language>fr</language>
"""
FOOTER = "  </channel>\n</rss>\n"


def main() -> None:
    path, version, url, signature = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4].strip()
    notes = Path(sys.argv[5]).read_text().strip() if len(sys.argv) > 5 else f"VoxFlow {version}"
    if not re.fullmatch(r'sparkle:edSignature="[^"]+" length="\d+"', signature):
        sys.exit(f"Signature inattendue : {signature!r}")

    existing = path.read_text() if path.exists() else HEADER + FOOTER
    # Signature et avertissement de sign_update retirés : il les recalcule après l'ajout.
    existing = re.sub(r"<!-- sparkle-(signatures|sign-warning):.*?-->", "", existing, flags=re.S)
    if f"<sparkle:version>{html.escape(version)}</sparkle:version>" in existing:
        sys.exit(f"La version {version} est déjà dans {path}")

    paragraphs = "".join(f"<p>{html.escape(p.strip())}</p>" for p in notes.split("\n\n") if p.strip())
    item = f"""    <item>
      <title>VoxFlow {html.escape(version)}</title>
      <pubDate>{formatdate(localtime=False, usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{paragraphs}]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {signature}/>
    </item>
"""
    marker = "    <language>fr</language>\n"
    assert marker in existing, "appcast sans en-tête VoxFlow"
    path.write_text(existing.replace(marker, marker + item, 1))
    print(f"{path} : version {version} ajoutée")


if __name__ == "__main__":
    main()
