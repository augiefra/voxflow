"""Tests du démon sans modèles : python -m unittest test_inference_daemon"""

import asyncio
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

import numpy as np
from websockets.asyncio.client import connect

import inference_daemon as d


def seed(db: Path, rows: list[tuple[str, str, str, str, int]]) -> d.Lexicon:
    lex = d.Lexicon(db)
    with sqlite3.connect(db) as conn:
        conn.executemany(
            "INSERT INTO lexicon (wrong_variant, canonical_term, context_hint, app_bundle_id, "
            "frequency, updated_at) VALUES (?,?,?,?,?, datetime('now'))",
            rows,
        )
    return lex


class TextTests(unittest.TestCase):
    def test_phonetic_keys(self):
        self.assertEqual(d.phonetic_fr("facil a beau"), d.phonetic_fr("FacilAbo"))
        self.assertEqual(d.phonetic_fr("facile à beau"), d.phonetic_fr("facilabo"))
        self.assertGreaterEqual(d.ratio(d.phonetic_fr("Allo"), d.phonetic_fr("Allauch")), 0.6)

    def test_deterministic_rules(self):
        entry = d.LexiconEntry("FacilAbo", ["facil a beau", "facilabo"])
        allauch = d.LexiconEntry("Allauch", ["Allo"])
        pairs = d.Lexicon.safe_deterministic_rules([entry, allauch])
        self.assertIn(("facil a beau", "FacilAbo"), pairs)
        self.assertNotIn(("Allo", "Allauch"), pairs)  # ambigu : laissé au LLM
        text = d.apply_deterministic("j'ai ouvert Facil a beau et facilabo ce matin", pairs)
        self.assertEqual(text, "j'ai ouvert FacilAbo et FacilAbo ce matin")

    def test_parse_rejects_answers(self):
        raw = "quelle est la capitale de la France"
        self.assertEqual(
            d.parse_llm_output("<texte_nettoye>Quelle est la capitale de la France ?</texte_nettoye>", raw),
            "Quelle est la capitale de la France ?",
        )
        self.assertIsNone(d.parse_llm_output("La capitale de la France est Paris.", raw))
        long_answer = "<texte_nettoye>" + "Paris est la capitale. " * 10 + "</texte_nettoye>"
        self.assertIsNone(d.parse_llm_output(long_answer, raw))

    def test_llm_gate(self):
        self.assertIsNone(d.llm_reason("J'ai mis à jour l'application ce matin.", []))
        self.assertIsNotNone(d.llm_reason("Bonjour, du coup la réunion est décalée.", []))
        self.assertIsNotNone(d.llm_reason("La réunion de mardi, non, de mercredi.", []))
        self.assertIsNotNone(d.llm_reason("je je pense que oui", []))
        allauch = d.LexiconEntry("Allauch", ["Alloche"], matched=True)
        self.assertIsNotNone(d.llm_reason("On se voit à Alloche.", [allauch]))
        facilabo = d.LexiconEntry("FacilAbo", ["Facilabo"], matched=True)
        self.assertIsNone(d.llm_reason("Facilabo est en ligne.", [facilabo]))

    def test_french_typography(self):
        self.assertEqual(d.french_typography("Tu viens?Oui!"), "Tu viens?Oui !")
        self.assertEqual(d.french_typography("ça va? oui"), "Ça va ? oui")
        self.assertEqual(d.french_typography("Voir https://a.fr/x?y=1 à 15:30. Note: ok"),
                         "Voir https://a.fr/x?y=1 à 15:30. Note : ok")

    def test_fallback_clean(self):
        self.assertEqual(d.fallback_clean("euh bonjour bah ça va"), "Bonjour ça va.")


class LexiconTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "lexicon.db"
        self.lex = seed(
            self.db,
            [
                ("Allo", "Allauch", "rendez-vous à … demain matin", "com.apple.mail", 3),
                ("facil a beau", "FacilAbo", "l'app … est en ligne", "com.tinyspeck.slackmacgap", 5),
                ("facile à beau", "FacilAbo", "", "com.apple.TextEdit", 1),
                ("ever volt", "EuroVolt", "", "com.apple.TextEdit", 1),
            ],
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_select_groups_and_prioritises_matches(self):
        entries = self.lex.select("on se retrouve à allo avec l'équipe facile a beau", "com.apple.mail")
        by_term = {e.canonical_term: e for e in entries}
        self.assertTrue(by_term["Allauch"].matched)
        self.assertTrue(by_term["FacilAbo"].matched)
        self.assertFalse(by_term["EuroVolt"].matched)  # présent via le Top N, pas via le texte
        self.assertEqual(set(by_term["FacilAbo"].variants), {"facil a beau", "facile à beau"})
        self.assertTrue(entries[-1].canonical_term == "EuroVolt")

    def test_dictionary_block_format(self):
        block = d.build_dictionary_block(self.lex.select("allo", ""))
        self.assertIn("<dictionnaire_utilisateur>", block)
        self.assertIn('"Allo" (contexte : « rendez-vous à … demain matin ») -> "Allauch"', block)
        self.assertIn('"facil a beau" / "facile à beau" (contexte : « l\'app … est en ligne ») -> "FacilAbo"', block)
        self.assertIn('- "ever volt" -> "EuroVolt"', block)


class ServerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        seed(base / "lexicon.db", [("facil a beau", "FacilAbo", "", "", 2)])
        self.args = d.parse_args(
            ["--mock", "--port", "8799", "--db", str(base / "lexicon.db"),
             "--token-file", str(base / "token")]
        )
        self.server = asyncio.create_task(d.run_server(self.args))
        for _ in range(50):
            if (base / "token").exists():
                break
            await asyncio.sleep(0.05)
        await asyncio.sleep(0.2)
        self.token = (base / "token").read_text()

    async def asyncTearDown(self):
        self.server.cancel()
        try:
            await self.server
        except asyncio.CancelledError:
            pass
        self.tmp.cleanup()

    async def test_streaming_dictation_round_trip(self):
        headers = {"Authorization": f"Bearer {self.token}"}
        async with connect("ws://127.0.0.1:8799/v1/dictation", additional_headers=headers) as ws:
            await ws.send(json.dumps({"type": "start", "bundle_id": "com.apple.TextEdit", "sample_rate": 16000}))
            self.assertEqual(json.loads(await ws.recv())["type"], "ready")
            for _ in range(10):
                await ws.send(np.zeros(1600, dtype="<f4").tobytes())
            await ws.send(json.dumps({"type": "stop"}))
            while True:
                msg = json.loads(await ws.recv())
                if msg["type"] != "partial":
                    break
            self.assertEqual(msg["type"], "final")
            self.assertIn("1.0 secondes", msg["raw"])
            self.assertTrue(msg["text"].startswith("FacilAbo test"))
            self.assertEqual(msg["lexicon_terms"], ["FacilAbo"])

    async def test_rejects_missing_token_and_browser_origin(self):
        with self.assertRaises(Exception):
            async with connect("ws://127.0.0.1:8799/v1/dictation"):
                pass
        headers = {"Authorization": f"Bearer {self.token}"}
        with self.assertRaises(Exception):
            async with connect("ws://127.0.0.1:8799/v1/dictation", additional_headers=headers,
                               origin="https://evil.example"):
                pass


if __name__ == "__main__":
    unittest.main()
