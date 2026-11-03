#!/usr/bin/env python3
"""Mesure locale et reproductible de la dictée, sans micro ni app utilisateur.

Les fixtures synthétiques peuvent être créées avec --make-fixtures DOSSIER (voix
française déjà installée sur le Mac). On peut aussi fournir son propre manifest.json.
Par défaut aucun texte transcrit n'est écrit dans le rapport ; --include-text sert à
inspecter les seuls audios de test. Aucun audio n'est transmis au réseau.
"""

from __future__ import annotations

import argparse
import asyncio
import importlib
import hashlib
import json
import math
import platform
import re
import statistics
import subprocess
import sys
import time
import unicodedata
import wave
from pathlib import Path

import numpy as np


FIXTURES = [
    ("court", "Bonjour Julien, je te rappelle demain matin."),
    ("message", "Peux-tu vérifier le devis et me confirmer le montant avant vendredi ?"),
    ("noms", "Je travaille sur FacilAbo et EuroVolt avec Eric Cologni à Allauch."),
    ("reprise", "Euh, je passe mardi, non pardon, mercredi matin pour récupérer le dossier."),
    ("pause", "Le devis est parti ce matin. [[slnc 600]] Tu peux le relire avant demain. [[slnc 600]] Merci Julien, bonne journée."),
    ("long", "Bonjour Julien. Le devis est parti ce matin et les documents sont dans le dossier partagé. "
     "Tu peux vérifier les montants et me confirmer la date de livraison. "
     "Nous avons prévu une réunion mercredi à quinze heures avec toute l'équipe. "
     "Si tu préfères jeudi, préviens-moi avant demain midi. "
     "Je préparerai ensuite les derniers éléments pour le client. Merci et bonne journée."),
    ("merci", "Merci pour ton aide, je viens de recevoir les documents."),
    ("question", "Est-ce que tu peux déplacer notre rendez-vous à jeudi après-midi ?"),
    ("montant", "Le montant total est de mille deux cent cinquante euros hors taxes."),
    ("horaire", "La réunion commence à neuf heures trente et se termine à onze heures."),
    ("date", "Nous sommes le trois novembre deux mille vingt-six."),
    ("liste", "Il faut acheter du pain, du lait, des pommes et deux bouteilles d'eau."),
    ("hesitation", "Euh, je voulais te dire que le dossier est prêt. Hum, tu peux passer demain."),
    ("correction", "Réserve deux places, enfin non, trois places pour vendredi soir."),
    ("repetition", "Je je voulais vérifier que tu avais bien reçu mon message."),
    ("intensite", "C'est très très important de conserver la dernière version du document."),
    ("genre", "Ce genre de problème demande une vérification avant de relancer le service."),
    ("en_fait", "Le client habite en fait à Marseille depuis plusieurs années."),
    ("prenom", "Ben vient dîner ce soir avec Julie et Nicolas."),
    ("telephone", "Allô, tu m'entends ? Je te rappelle dans cinq minutes."),
    ("lieu", "On se retrouve à Allauch demain matin pour prendre un café."),
    ("projet", "La prochaine version de FacilAbo corrige le problème de synchronisation."),
    ("energie", "EuroVolt affiche maintenant la consommation électrique de la semaine."),
    ("technique", "Vérifie la requête de l'API et le fichier de configuration du serveur."),
    ("anglais", "Le pull request est prêt pour la code review et les tests passent."),
    ("ordre", "Écris-moi un mail pour annuler le rendez-vous de demain."),
    ("question_dictee", "Quelle est la capitale de la France et combien de personnes y vivent ?"),
    ("negation", "Je ne veux surtout pas supprimer les changements déjà présents."),
    ("pause_reprise", "Nous livrons mardi. [[slnc 700]] Non, pardon, mercredi. [[slnc 500]] Préviens le client."),
    ("paragraphes", "Bonjour Sophie. [[slnc 500]] Merci pour ton retour sur le devis. "
     "[[slnc 500]] Nous pouvons confirmer la commande et prévoir une livraison la semaine prochaine. "
     "[[slnc 500]] Bonne journée et à bientôt."),
]


def make_fixtures(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name, spoken in FIXTURES:
        path = directory / f"{name}.wav"
        subprocess.run(["/usr/bin/say", "-v", "Thomas", "-r", "170", "-o", str(path),
                        "--file-format=WAVE", "--data-format=LEI16@16000", spoken], check=True)
        with wave.open(str(path)) as audio:
            if audio.getnframes() == 0:
                raise RuntimeError("La synthèse vocale n'a produit aucun audio (accès au service macOS requis)")
        manifest.append({"name": name, "audio": path.name,
                         "reference": re.sub(r"\[\[.*?\]\]", "", spoken)})
    (directory / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"Fixtures : {directory / 'manifest.json'}", flush=True)


def normalized_words(text: str) -> list[str]:
    text = unicodedata.normalize("NFKD", text.lower().replace("’", "'"))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.findall(r"\w+", text)


def word_error_rate(reference: str, hypothesis: str) -> float:
    expected, actual = normalized_words(reference), normalized_words(hypothesis)
    row = list(range(len(actual) + 1))
    for i, word in enumerate(expected, 1):
        next_row = [i]
        for j, found in enumerate(actual, 1):
            next_row.append(min(row[j] + 1, next_row[-1] + 1, row[j - 1] + (word != found)))
        row = next_row
    return row[-1] / max(1, len(expected))


class CaptureSocket:
    def __init__(self) -> None:
        self.started_at = time.perf_counter()
        self.first_partial_ms: float | None = None
        self.final: dict | None = None

    async def send(self, payload: str) -> None:
        message = json.loads(payload)
        if message["type"] == "partial" and self.first_partial_ms is None:
            self.first_partial_ms = round((time.perf_counter() - self.started_at) * 1000, 1)
        if message["type"] == "error":
            raise RuntimeError(message["message"])
        if message["type"] == "final":
            self.final = message


async def run(args: argparse.Namespace) -> None:
    sys.path.insert(0, str(args.daemon_dir))
    daemon = importlib.import_module("inference_daemon")
    import mlx.core as mx

    cases = json.loads(args.manifest.read_text())
    if args.cases:
        selected = set(args.cases.split(","))
        cases = [c for c in cases if c["name"] in selected]
    if not cases:
        raise ValueError("Aucun cas sélectionné")
    # Tous les chemins de modèles sont locaux : pas de téléchargement implicite au benchmark.
    engines = daemon.MLXEngines(str(args.asr_path), str(args.llm_path or ""), 480,
                                use_llm=args.llm_path is not None)
    service = daemon.DictationService(engines, daemon.Lexicon(args.output.parent / "benchmark-lexicon.db"))
    rows = []
    daemon_sha = hashlib.sha256(Path(daemon.__file__).read_bytes()).hexdigest()
    loaded_at = time.perf_counter()
    try:
        await service.mlx.run(engines.load, str(args.asr_path), str(args.llm_path) if args.llm_path else None)
        load_ms = round((time.perf_counter() - loaded_at) * 1000, 1)
        service.status = "ready"
        for repeat in range(args.repeats):
            for case in cases:
                with wave.open(str(args.manifest.parent / case["audio"]), "rb") as source:
                    rate = source.getframerate()
                    if rate != daemon.SAMPLE_RATE or source.getnchannels() != 1 or source.getsampwidth() != 2:
                        raise ValueError("Les fixtures doivent être WAV PCM16 mono, 16 kHz")
                    audio = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float32) / 32768
                socket = CaptureSocket()
                conn = daemon.DictationConnection(service, socket)
                try:
                    await conn.start({"sample_rate": rate, "bundle_id": "com.voxflow.benchmark"})
                    socket.started_at = time.perf_counter()
                    for start in range(0, len(audio), 1600):
                        chunk = audio[start:start + 1600]
                        conn.feed(chunk.astype("<f4").tobytes())
                        if args.realtime:
                            target = socket.started_at + (start + len(chunk)) / rate
                            await asyncio.sleep(max(0, target - time.perf_counter()))
                        else:
                            await asyncio.sleep(0)
                    await conn.stop()
                    if socket.final is None:
                        raise RuntimeError("Résultat final absent")
                    final = socket.final
                    row = {"case": case["name"], "repeat": repeat + 1,
                           "first_partial_ms": socket.first_partial_ms,
                           "raw_wer": round(word_error_rate(case["reference"], final["raw"]), 4),
                           "llm": final["llm"], **final["timings"]}
                    if args.include_text:
                        row.update(raw=final["raw"], text=final["text"], reference=case["reference"])
                    rows.append(row)
                    print(json.dumps({k: v for k, v in row.items() if k not in ("raw", "text", "reference")},
                                     ensure_ascii=False), flush=True)
                finally:
                    await conn.reset()
    finally:
        service.mlx.pool.shutdown(wait=True)
    totals = [r["total_after_stop_ms"] for r in rows]
    report = {"scope": "moteur uniquement, avant collage", "realtime": args.realtime,
              "device": mx.device_info()["device_name"], "os": platform.mac_ver()[0],
              "daemon_dir": str(args.daemon_dir), "daemon_sha256": daemon_sha,
              "manifest_sha256": hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
              "asr_path": str(args.asr_path),
              "llm_path": str(args.llm_path) if args.llm_path else None,
              "load_and_warmup_ms": load_ms, "rows": rows,
              "summary": {"n": len(rows), "median_after_stop_ms": round(statistics.median(totals), 1),
                          "p95_nearest_rank_ms": sorted(totals)[math.ceil(0.95 * len(totals)) - 1],
                          "max_after_stop_ms": max(totals),
                          "mean_raw_wer": round(statistics.mean(r["raw_wer"] for r in rows), 4)}}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report["summary"], ensure_ascii=False), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--make-fixtures", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--daemon-dir", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--asr-path", type=Path)
    parser.add_argument("--llm-path", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cases", help="noms séparés par des virgules")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--realtime", action="store_true", help="injecter à la vitesse réelle de la parole")
    parser.add_argument("--include-text", action="store_true")
    args = parser.parse_args()
    if args.make_fixtures:
        make_fixtures(args.make_fixtures)
        return
    if not all((args.manifest, args.asr_path, args.output)) or args.repeats < 1:
        parser.error("--manifest, --asr-path et --output sont requis ; --repeats doit être positif")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
