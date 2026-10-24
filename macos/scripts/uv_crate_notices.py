#!/usr/bin/env python3
"""Mentions des bibliothèques Rust (crates) liées dans le binaire uv embarqué.

uv est redistribué dans l'app : les licences MIT, BSD, ISC… de ses crates demandent de
reproduire leurs mentions. Le script lit Cargo.lock au tag de la version, télécharge
chaque crate depuis crates.io (en mémoire, rien n'est extrait sur le disque) et en garde
les fichiers de licence. Les textes génériques (Apache 2.0, MPL 2.0) ne sont pas répétés.
À relancer à chaque changement de version de uv (scripts/fetch_uv.sh).

Usage : uv_crate_notices.py <version uv> <sortie>
"""
import io
import sys
import tarfile
import tomllib
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HEADERS = {"User-Agent": "voxflow-notices (https://github.com/augiefra/voxflow)"}
LICENSE_PREFIXES = ("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE")


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60) as response:
        return response.read()


def generic(text: str) -> str | None:
    """Texte de licence générique (sans mention d'auteur propre au crate) : on renvoie son nom."""
    head = text[:400]
    if "Apache License" in head and "Version 2.0, January 2004" in head and "Copyright" not in text[-1500:].replace("Copyright [yyyy]", ""):
        return "Apache-2.0"
    if head.startswith("Mozilla Public License Version 2.0"):
        return "MPL-2.0"
    return None


def crate_licenses(name: str, version: str) -> tuple[str, list[tuple[str, str]]]:
    data = fetch(f"https://static.crates.io/crates/{name}/{name}-{version}.crate")
    expression, texts = "", []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            parts = member.name.split("/")
            if len(parts) != 2 or not member.isfile():
                continue
            filename = parts[1]
            if filename == "Cargo.toml":
                manifest = tomllib.loads(archive.extractfile(member).read().decode("utf-8", "replace"))
                expression = manifest.get("package", {}).get("license", "") or ""
            elif filename.upper().startswith(LICENSE_PREFIXES):
                texts.append((filename, archive.extractfile(member).read().decode("utf-8", "replace").strip()))
    return expression, sorted(texts)


def chosen(expression: str, texts: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Licence au choix (« MIT OR Apache-2.0 ») : on retient MIT et on ne garde que ses fichiers.
    Les licences cumulées (AND) gardent tous leurs fichiers."""
    if "AND" in expression or "(" in expression or "MIT" not in expression.split(" OR "):
        return texts
    mit = [(name, text) for name, text in texts if "MIT" in name.upper()]
    if not mit:
        mit = [(name, text) for name, text in texts if "Permission is hereby granted, free of charge" in text]
    notices = [(name, text) for name, text in texts if name.upper().startswith("NOTICE")]
    return (mit + notices) or texts


def main() -> None:
    version, output = sys.argv[1], sys.argv[2]
    lock = tomllib.loads(fetch(f"https://raw.githubusercontent.com/astral-sh/uv/{version}/Cargo.lock").decode())
    packages = lock["package"]
    registry = [(p["name"], p["version"]) for p in packages if p.get("source", "").startswith("registry+")]
    git = sorted({(p["name"], p["version"], p["source"]) for p in packages if p.get("source", "").startswith("git+")})
    workspace = sorted(p["name"] for p in packages if "source" not in p)

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda item: (item, crate_licenses(*item)), sorted(set(registry))))

    lines = [
        f"Crates Rust liés dans uv {version} (d'après Cargo.lock au tag {version}, toutes plateformes confondues).",
        "Les textes Apache 2.0 et MPL 2.0 génériques ne sont pas répétés : voir la fin de THIRD_PARTY_NOTICES.txt",
        "et https://www.mozilla.org/MPL/2.0/.",
        "",
        f"Composants de uv lui-même (licence de uv) : {', '.join(workspace)}",
        "",
    ]
    for (name, crate_version), (expression, texts) in results:
        kept = chosen(expression, texts)
        choice = " (retenue : MIT)" if kept is not texts and len(kept) < len(texts) else ""
        lines += ["-" * 78, f"{name} {crate_version} — {expression or 'licence non déclarée'}{choice}"]
        for filename, text in kept:
            kind = generic(text)
            lines += [f"[{filename} : texte {kind} générique]" if kind else f"[{filename}]\n{text}"]
        if not texts:
            lines.append("(aucun fichier de licence dans le crate ; licence déclarée ci-dessus)")
    for name, crate_version, source in git:
        lines += ["-" * 78, f"{name} {crate_version} — dépendance Git : {source}"]
    with open(output, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print(f"{output} : {len(results)} crates, {len(git)} dépendances Git")


if __name__ == "__main__":
    main()
