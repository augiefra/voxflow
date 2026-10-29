"""Tests du démon sans modèles : python -m unittest test_inference_daemon"""

import asyncio
import json
import logging
import os
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


    def test_plan_segments_sends_only_sentences_to_clean(self):
        sentences = d.split_sentences("Bonjour Julien. Le devis est parti. Euh je passe demain. À jeudi !")
        self.assertEqual(len(sentences), 4)
        self.assertEqual(
            d.plan_segments(sentences, [False, False, True, False]),
            [("Bonjour Julien. Le devis est parti.", False), ("Euh je passe demain.", True), ("À jeudi !", False)],
        )

    def test_plan_segments_keeps_the_sentence_a_reprise_corrects(self):
        sentences = ["On livre mardi.", "Non, pardon, mercredi.", "Merci."]
        self.assertEqual(
            d.plan_segments(sentences, [False, True, False]),
            [("On livre mardi. Non, pardon, mercredi.", True), ("Merci.", False)],
        )


class SegmentedCleanTests(unittest.IsolatedAsyncioTestCase):
    async def test_long_dictation_sends_only_flagged_sentences(self):
        sent = []

        class Engines(d.MockEngines):
            def complete(self, messages, max_tokens):
                sent.append(messages[-1]["content"])
                return super().complete(messages, max_tokens)

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(Engines(), d.Lexicon(Path(tmp) / "lexicon.db"))
            text, _, timings, reason = await service.clean(
                "Bonjour Julien. Le devis est parti hier. Euh je passe demain. À jeudi !", "")
        self.assertEqual(sent, ["<transcription>Euh je passe demain.</transcription>"])
        self.assertEqual(text, "Bonjour Julien. Le devis est parti hier. Je passe demain. À jeudi !")
        self.assertEqual(timings["llm_chars"], len("Euh je passe demain."))
        self.assertIn("1 segment(s) sur 4 phrases", reason)

    async def test_short_dictation_goes_whole(self):
        sent = []

        class Engines(d.MockEngines):
            def complete(self, messages, max_tokens):
                sent.append(messages[-1]["content"])
                return super().complete(messages, max_tokens)

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(Engines(), d.Lexicon(Path(tmp) / "lexicon.db"))
            await service.clean("Bonjour. Euh je passe demain.", "")
        self.assertEqual(sent, ["<transcription>Bonjour. Euh je passe demain.</transcription>"])


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


class PrepareTests(unittest.TestCase):
    """Modèles personnalisés : le magasin ne s'en charge pas, et le Hub reste en ligne pour eux."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.calls = []
        self._saved = (d.model_store.check_machine, d.model_store.ensure_models)
        d.model_store.check_machine = lambda **_: None

        def fake_ensure(keys, progress, **_):
            self.calls.append(list(keys))
            return progress, {k: Path("/magasin") / k for k in keys}

        d.model_store.ensure_models = fake_ensure

    def tearDown(self):
        d.model_store.check_machine, d.model_store.ensure_models = self._saved
        self.tmp.cleanup()

    def service(self, asr: str, llm: str, use_llm: bool) -> d.DictationService:
        engines = d.MLXEngines(asr, llm, 480, use_llm=use_llm)
        return d.DictationService(engines, d.Lexicon(Path(self.tmp.name) / "lexicon.db"))

    def test_custom_asr_skips_store(self):
        service = self.service("moi/autre-asr", d.DEFAULT_LLM_MODEL, use_llm=False)
        paths = service.prepare()
        self.assertEqual(paths, {"asr": None, "llm": None})
        self.assertEqual(self.calls, [])
        self.assertFalse(service.engines.all_local(paths["asr"], paths["llm"]))   # Hub en ligne
        self.assertEqual(service.progress.snapshot()["bytes_total"], 0)

    def test_custom_llm_keeps_store_for_asr(self):
        service = self.service(d.DEFAULT_ASR_MODEL, "moi/autre-llm", use_llm=True)
        paths = service.prepare()
        self.assertEqual(self.calls, [["asr"]])
        self.assertEqual(paths, {"asr": Path("/magasin/asr"), "llm": None})
        self.assertFalse(service.engines.all_local(paths["asr"], paths["llm"]))

    def test_default_models_load_offline(self):
        service = self.service(d.DEFAULT_ASR_MODEL, d.DEFAULT_LLM_MODEL, use_llm=True)
        paths = service.prepare()
        self.assertEqual(self.calls, [["asr", "llm"]])
        self.assertTrue(service.engines.all_local(paths["asr"], paths["llm"]))


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

    async def get(self, path: str, host: str, extra: str = "") -> str:
        reader, writer = await asyncio.open_connection("127.0.0.1", 8799)
        writer.write(f"GET {path} HTTP/1.1\r\nHost: {host}\r\n{extra}Connection: close\r\n\r\n".encode())
        await writer.drain()
        data = await reader.read()
        writer.close()
        return data.decode()

    async def test_health_contract_and_host_check(self):
        os.environ["VOXFLOW_APP_VERSION"] = "9.9.9"
        try:
            reply = await self.get("/health", "127.0.0.1:8799")
        finally:
            os.environ.pop("VOXFLOW_APP_VERSION", None)
        self.assertIn(" 200 ", reply.split("\r\n", 1)[0])
        body = json.loads(reply.split("\r\n\r\n", 1)[1])
        self.assertEqual((body["pid"], body["mode"], body["version"]), (os.getpid(), "full", "9.9.9"))
        for key in ("status", "error", "phase", "bytes_done", "bytes_total", "disk_free_bytes", "retry"):
            self.assertIn(key, body)
        self.assertIn(" 200 ", (await self.get("/health", "localhost:8799")).split("\r\n", 1)[0])
        # DNS rebinding (Host d'un site) et page web (Origin) : refusés, /health compris.
        self.assertIn(" 421 ", (await self.get("/health", "evil.example:8799")).split("\r\n", 1)[0])
        self.assertIn(" 421 ", (await self.get("/health", "127.0.0.1:80")).split("\r\n", 1)[0])
        self.assertIn(" 403 ", (await self.get("/health", "127.0.0.1:8799", "Origin: https://evil.example\r\n"))
                      .split("\r\n", 1)[0])

    async def test_streaming_dictation_round_trip(self):
        headers = {"Authorization": f"Bearer {self.token}"}
        with self.assertLogs(d.log, logging.INFO) as logs:
            await self.dictate(headers)
        # Le journal peut être copié dans un ticket : aucun mot dicté au niveau INFO.
        self.assertTrue(any(r.getMessage().startswith("Dictée") for r in logs.records))
        for record in logs.records:
            self.assertNotIn("facil", record.getMessage().lower())
            self.assertNotIn("secondes", record.getMessage())

    async def dictate(self, headers: dict) -> None:
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
