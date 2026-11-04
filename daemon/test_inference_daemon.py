"""Tests du démon sans modèles : python -m unittest test_inference_daemon"""

import asyncio
import importlib.metadata
import importlib.util
import json
import logging
import os
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

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

    def test_lexicon_gate_catches_unresolved_phonetic_variants(self):
        entry = d.LexiconEntry("FacilAbo", ["facil a beau"], matched=True)
        self.assertIsNotNone(d.llm_reason("Je travaille sur Facile Abo.", [entry]))
        self.assertIsNone(d.llm_reason("Je travaille sur FacilAbo.", [entry]))
        ambiguous = d.LexiconEntry("Allauch", ["Allo"], matched=True)
        self.assertIsNone(d.llm_reason("Je passe à Allauch.", [ambiguous]))
        self.assertIsNotNone(d.llm_reason("On parle d'Allauch et on entend Allo.", [ambiguous]))

    def test_french_typography(self):
        self.assertEqual(d.french_typography("Tu viens?Oui!"), "Tu viens?Oui !")
        self.assertEqual(d.french_typography("ça va? oui"), "Ça va ? oui")
        self.assertEqual(d.french_typography("Voir https://a.fr/x?y=1 à 15:30. Note: ok"),
                         "Voir https://a.fr/x?y=1 à 15:30. Note : ok")

    def test_fallback_clean(self):
        self.assertEqual(d.fallback_clean("euh bonjour ça va"), "Bonjour ça va.")
        self.assertEqual(d.fallback_clean("Ben vient dîner ce soir"), "Ben vient dîner ce soir.")
        self.assertEqual(d.fallback_clean("Ce genre de cas existe en fait souvent"),
                         "Ce genre de cas existe en fait souvent.")

    def test_literal_hesitation_is_preserved(self):
        for quoted in ['"euh"', '« euh »', '“hum”', '`heu`']:
            text = f"Le mot {quoted} est une hésitation."
            self.assertEqual(d.remove_simple_fillers(text), text)
            self.assertIsNone(d.llm_reason(text, []))

    def test_meaningful_words_and_emphasis_do_not_trigger_cleanup(self):
        for text in ["Ben vient dîner ce soir.", "Ce genre de problème existe.",
                     "Le client habite en fait à Marseille.", "C'est très très important.", "Oui oui, je viens."]:
            self.assertIsNone(d.llm_reason(text, []), text)


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
            def complete(self, messages, max_tokens, **kwargs):
                sent.append(messages[-1]["content"])
                return "<texte_nettoye>Je passe demain.</texte_nettoye>"

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(Engines(), d.Lexicon(Path(tmp) / "lexicon.db"))
            text, _, timings, reason = await service.clean(
                "Bonjour Julien. Le devis est parti hier. Je je passe demain. À jeudi !", "")
        self.assertEqual(sent, ["<transcription>Je je passe demain.</transcription>"])
        self.assertEqual(text, "Bonjour Julien. Le devis est parti hier. Je passe demain. À jeudi !")
        self.assertEqual(timings["llm_chars"], len("Je je passe demain."))
        self.assertIn("1 segment(s) sur 4 phrases", reason)

    async def test_short_dictation_goes_whole(self):
        sent = []

        class Engines(d.MockEngines):
            def complete(self, messages, max_tokens, **kwargs):
                sent.append(messages[-1]["content"])
                return super().complete(messages, max_tokens, **kwargs)

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(Engines(), d.Lexicon(Path(tmp) / "lexicon.db"))
            await service.clean("Bonjour. Je je passe demain.", "")
        self.assertEqual(sent, ["<transcription>Bonjour. Je je passe demain.</transcription>"])

    async def test_simple_hesitation_needs_no_generation(self):
        sent = []

        class Engines(d.MockEngines):
            def complete(self, *args, **kwargs):
                sent.append(True)
                return super().complete(*args, **kwargs)

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(Engines(), d.Lexicon(Path(tmp) / "lexicon.db"))
            text, _, timings, reason = await service.clean("Euh, je passe demain. Hum, à jeudi !", "")
        self.assertEqual(text, "Je passe demain. À jeudi !")
        self.assertEqual(sent, [])
        self.assertEqual(reason, "évité")
        self.assertNotIn("llm_ms", timings)

    async def test_budget_is_shared_and_worker_is_free_before_returning(self):
        calls = []

        class SlowEngines(d.MockEngines):
            def complete(self, messages, max_tokens, *, deadline=None):
                calls.append(messages[-1]["content"])
                while time.perf_counter() < deadline:
                    time.sleep(0.001)
                raise d.GenerationBudgetExceeded()

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(SlowEngines(), d.Lexicon(Path(tmp) / "lexicon.db"), llm_budget_s=0.02)
            start = time.perf_counter()
            text, _, timings, _ = await service.clean(
                "Je je passe demain. Le devis est validé. Je je rappelle jeudi.", "")
            self.assertEqual(await service.mlx.run(lambda: "worker libre"), "worker libre")
            service.mlx.pool.shutdown(wait=True)
        self.assertLess(time.perf_counter() - start, 0.5)
        self.assertEqual(len(calls), 1)  # pas un nouveau budget pour le second segment
        self.assertEqual(timings["budget_exceeded"], 2)
        self.assertEqual(timings["fallback"], 2)
        self.assertEqual(text, "Je je passe demain. Le devis est validé. Je je rappelle jeudi.")


class GenerationBudgetTests(unittest.TestCase):
    def test_expired_budget_closes_generation_before_next_token(self):
        state = []

        def stream():
            try:
                yield SimpleNamespace(text="incomplet")
                state.append("continué")
            finally:
                state.append("fermé")

        with self.assertRaises(d.GenerationBudgetExceeded):
            d.collect_generation(stream(), deadline=0)
        self.assertEqual(state, ["fermé"])

    def test_closing_tag_stops_generation_and_preserves_whole_result(self):
        state = []

        def stream():
            try:
                for text in ["<texte_nettoye>Bonjour.", "</texte_", "nettoye>"]:
                    yield SimpleNamespace(text=text)
                state.append("commentaire superflu")
            finally:
                state.append("fermé")

        self.assertEqual(d.collect_generation(stream(), None), "<texte_nettoye>Bonjour.</texte_nettoye>")
        self.assertEqual(state, ["fermé"])


class WakeDuringAudioTests(unittest.IsolatedAsyncioTestCase):
    class Socket:
        def __init__(self):
            self.messages = []

        async def send(self, payload):
            self.messages.append(json.loads(payload))

    async def test_short_capture_keeps_quiet_speech_without_speculative_wake(self):
        class Model:
            def __init__(self):
                self.audio = None

            def generate(self, audio, **kwargs):
                self.audio = audio
                return SimpleNamespace(text="Bonjour.")

        class Engines(d.MockEngines):
            def create_session(self, hint=""):
                self.model = Model()
                return d.ChunkedSession(self.model)

            def wake_if_idle(self):
                raise AssertionError("une capture brève ne doit pas lancer le réveil")

        with tempfile.TemporaryDirectory() as tmp:
            engine = Engines()
            service = d.DictationService(engine, d.Lexicon(Path(tmp) / "lexicon.db"))
            service.status = "ready"
            socket = self.Socket()
            conn = d.DictationConnection(service, socket)
            audio = np.random.default_rng(7).normal(0, 0.00001, 9600).astype("<f4")
            try:
                await conn.start({})
                conn.feed(audio.tobytes())
                await conn.stop()
                np.testing.assert_array_equal(engine.model.audio, audio)
                final = next(m for m in socket.messages if m["type"] == "final")
                self.assertEqual(final["text"], "Bonjour.")
                self.assertEqual(final["timings"]["wake_during_audio_ms"], 0)
            finally:
                await conn.reset()
                service.mlx.pool.shutdown(wait=True)

    async def test_empty_and_digital_silence_do_not_wake_or_mark_models_active(self):
        class Engines(d.MockEngines):
            def create_session(self, hint=""):
                return d.ChunkedSession(SimpleNamespace(generate=self.unexpected))

            def unexpected(self, *args, **kwargs):
                raise AssertionError("aucune inférence sur le silence numérique")

            wake_if_idle = unexpected
            mark_active = unexpected

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(Engines(), d.Lexicon(Path(tmp) / "lexicon.db"))
            service.status = "ready"
            socket = self.Socket()
            conn = d.DictationConnection(service, socket)
            try:
                for seconds in (0, 0.6, 2):
                    with self.subTest(seconds=seconds):
                        await conn.start({})
                        conn.feed(np.zeros(int(seconds * d.SAMPLE_RATE), dtype="<f4").tobytes())
                        # Donne au pump l'occasion de préparer un réveil pendant la capture.
                        await asyncio.sleep(0.05)
                        await conn.stop()
                        final = socket.messages[-1]
                        self.assertEqual(final["type"], "final")
                        self.assertEqual(final["text"], "")
                        self.assertEqual(final["timings"]["wake_during_audio_ms"], 0)
            finally:
                await conn.reset()
                service.mlx.pool.shutdown(wait=True)

    async def test_audio_keeps_arriving_while_the_worker_wakes(self):
        class Engines(d.MockEngines):
            def __init__(self):
                self.started = threading.Event()
                self.finished = threading.Event()

            def wake_if_idle(self):
                self.started.set()
                time.sleep(0.05)
                self.finished.set()
                return 50.0

        with tempfile.TemporaryDirectory() as tmp:
            engine = Engines()
            service = d.DictationService(engine, d.Lexicon(Path(tmp) / "lexicon.db"))
            service.status = "ready"
            socket = self.Socket()
            conn = d.DictationConnection(service, socket)
            try:
                await conn.start({"sample_rate": 16000})
                await asyncio.sleep(0.01)
                self.assertFalse(engine.started.is_set())
                conn.feed(np.ones(d.SAMPLE_RATE, dtype="<f4").tobytes())
                for _ in range(100):
                    if engine.started.is_set():
                        break
                    await asyncio.sleep(0.001)
                self.assertTrue(engine.started.is_set())
                conn.feed(np.zeros(d.SAMPLE_RATE, dtype="<f4").tobytes())
                self.assertFalse(engine.finished.is_set())
                await conn.stop()
                final = next(m for m in socket.messages if m["type"] == "final")
                self.assertIn("2.0 secondes", final["raw"])
                self.assertEqual(final["timings"]["wake_during_audio_ms"], 50.0)
            finally:
                await conn.reset()
                service.mlx.pool.shutdown(wait=True)

    def test_speculative_wake_never_runs_qwen(self):
        calls = []
        model_type = type("Parakeet", (), {"__module__": "mlx_audio.stt.models.parakeet"})
        model = model_type()
        model.generate = lambda audio: calls.append(audio)
        engine = d.MLXEngines("asr", "llm", 480, True)
        engine.asr = model
        engine.complete = lambda *args, **kwargs: self.fail("Qwen ne doit pas être réveillé sans texte")
        mx = SimpleNamespace(zeros=lambda count: np.zeros(count))
        with patch.dict("sys.modules", {"mlx": SimpleNamespace(core=mx), "mlx.core": mx}):
            engine.wake_if_idle()
        self.assertEqual(len(calls), 1)

    async def test_queued_wake_is_skipped_if_capture_closes_before_worker_is_free(self):
        class Engines(d.MockEngines):
            def wake_if_idle(self):
                raise AssertionError("la capture est fermée avant le démarrage du réveil")

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(Engines(), d.Lexicon(Path(tmp) / "lexicon.db"))
            conn = d.DictationConnection(service, self.Socket())
            session = d.MockSession()
            worker_entered, release_worker = threading.Event(), threading.Event()

            def occupy_worker():
                worker_entered.set()
                if not release_worker.wait(2):
                    raise AssertionError("test : worker non libéré")

            blocker = asyncio.create_task(service.mlx.run(occupy_worker))
            wake = None
            try:
                for _ in range(100):
                    if worker_entered.is_set():
                        break
                    await asyncio.sleep(0.001)
                self.assertTrue(worker_entered.is_set())
                wake = asyncio.create_task(service.mlx.run(conn._wake_if_recording, session))
                await asyncio.sleep(0)  # le réveil rejoint la file derrière occupy_worker
                session.close()
                release_worker.set()
                self.assertEqual(await wake, 0)
                await blocker
            finally:
                release_worker.set()
                await blocker
                if wake is not None:
                    await wake
                service.mlx.pool.shutdown(wait=True)



class ChunkedSessionTests(unittest.TestCase):
    class FakeWhisper:
        def __init__(self):
            self.calls = []

        def generate(self, audio, **kwargs):
            self.calls.append((audio.size, kwargs.get("initial_prompt")))
            return type("R", (), {"text": f"tranche {len(self.calls)}..."})()

    def speech(self, seconds):
        return np.random.default_rng(1).normal(0, 0.1, int(seconds * d.SAMPLE_RATE)).astype(np.float32)

    def test_transcribes_chunks_while_speaking_cut_on_silence(self):
        model = self.FakeWhisper()
        session = d.ChunkedSession(model)
        audio = self.speech(40)
        audio[22 * d.SAMPLE_RATE:int(22.5 * d.SAMPLE_RATE)] = 0     # pause à 22 s
        deltas = []
        for k in range(0, audio.size, 1600):
            session.feed(audio[k:k + 1600])
            deltas += session.step()
        self.assertEqual(deltas, ["tranche 1 "])                      # points de suspension retirés
        self.assertAlmostEqual(model.calls[0][0] / d.SAMPLE_RATE, 22.2, delta=0.3)
        session.close()
        deltas += session.step()
        self.assertTrue(session.done)
        self.assertEqual("".join(deltas), "tranche 1 tranche 2...")
        self.assertEqual(model.calls[1][1].strip(), "tranche 1...")   # contexte de la tranche précédente

    def test_silence_is_not_transcribed(self):
        model = self.FakeWhisper()
        session = d.ChunkedSession(model)
        session.feed(np.zeros(3 * d.SAMPLE_RATE, dtype=np.float32))
        session.close()
        self.assertEqual(session.step(), [])
        self.assertEqual(model.calls, [])

    def test_short_phrase_is_decoded_during_its_pause(self):
        model = self.FakeWhisper()
        session = d.ChunkedSession(model, "Vocabulaire : FacilAbo.")
        session.feed(self.speech(2))
        self.assertEqual(session.step(), [])
        session.feed(np.zeros(int(d.ChunkedSession.PAUSE_S * d.SAMPLE_RATE), dtype=np.float32))
        self.assertEqual(session.step(), ["tranche 1 "])
        self.assertFalse(session.closed)
        self.assertIn("FacilAbo", model.calls[0][1])
        # Terminer juste après ne relance pas une inférence sur le silence consommé.
        session.close()
        self.assertEqual(session.step(), [])
        self.assertTrue(session.done)
        self.assertEqual(len(model.calls), 1)

    def test_short_silence_inside_a_word_is_not_a_boundary(self):
        model = self.FakeWhisper()
        session = d.ChunkedSession(model)
        session.feed(self.speech(2))
        session.feed(np.zeros(d.SAMPLE_RATE // 10, dtype=np.float32))
        self.assertEqual(session.step(), [])
        self.assertEqual(model.calls, [])

    def test_quiet_speech_is_kept_and_not_mistaken_for_a_pause(self):
        model = self.FakeWhisper()
        session = d.ChunkedSession(model)
        quiet = self.speech(2) * 0.005  # sous l'ancien seuil moyen fixe
        session.feed(quiet)
        self.assertEqual(session.step(), [])
        session.feed(np.zeros(int(session.PAUSE_S * d.SAMPLE_RATE), dtype=np.float32))
        self.assertEqual(session.step(), ["tranche 1 "])
        self.assertEqual(len(model.calls), 1)

    def test_backlog_at_stop_stays_bounded_and_loses_no_audio(self):
        model = self.FakeWhisper()
        session = d.ChunkedSession(model)
        session.feed(self.speech(65))
        session.close()
        while not session.done:
            session.step()
        self.assertEqual(sum(size for size, _ in model.calls), 65 * d.SAMPLE_RATE)
        self.assertTrue(all(size <= session.CHUNK_MAX_S * d.SAMPLE_RATE for size, _ in model.calls))

    def test_backlog_at_stop_uses_the_quiet_boundary_too(self):
        model = self.FakeWhisper()
        session = d.ChunkedSession(model)
        audio = self.speech(40)
        audio[22 * d.SAMPLE_RATE:int(22.5 * d.SAMPLE_RATE)] = 0
        session.feed(audio)
        session.close()
        session.step()
        self.assertAlmostEqual(model.calls[0][0] / d.SAMPLE_RATE, 22.2, delta=0.3)

    def test_hallucinated_credits_are_removed(self):
        text = "Merci pour le devis. Sous-titres réalisés para la communauté d'Amara.org"
        self.assertEqual(d._WHISPER_HALLUCINATIONS.sub(" ", text).strip(), "Merci pour le devis.")


class ParakeetContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Les outils d'alignement du SDK sont en Python pur : les charger sans
        # importer son moteur MLX permet ces tests sans GPU ni modèle.
        path = importlib.metadata.distribution("mlx-audio").locate_file(
            "mlx_audio/stt/models/nemo/alignment.py")
        spec = importlib.util.spec_from_file_location("_voxflow_alignment_tests", path)
        cls.alignment = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.alignment
        spec.loader.exec_module(cls.alignment)

    def setUp(self):
        self.patches = patch.dict(sys.modules, {
            "mlx": SimpleNamespace(core=SimpleNamespace(array=lambda audio: audio)),
            "mlx.core": SimpleNamespace(array=lambda audio: audio),
            "mlx_audio.stt.models.nemo.alignment": self.alignment,
        })
        self.patches.start()
        self.addCleanup(self.patches.stop)

    def model(self, responses):
        alignment = self.alignment

        class Model:
            def __init__(self):
                self.calls = []

            def generate(self, audio):
                self.calls.append(audio.copy())
                tokens = [alignment.AlignedToken(i, text, start, duration)
                          for i, text, start, duration in responses[len(self.calls) - 1]]
                return alignment.sentences_to_result(alignment.tokens_to_sentences(tokens))

        return Model()

    def test_next_chunk_receives_audio_context_and_no_duplicate_words(self):
        model = self.model([
            [(1, "Bonjour", 0.1, 0.4), (2, " Julien.", 1.2, 0.4)],
            [(2, " Julien.", 0.2, 0.4), (3, " Je", 2.1, 0.2), (4, " reviens.", 2.4, 0.4)],
        ])
        session = d.ParakeetSession(model)
        first = np.arange(3 * d.SAMPLE_RATE, dtype=np.float32) / d.SAMPLE_RATE
        second = np.ones(d.SAMPLE_RATE, dtype=np.float32) * 0.00001
        self.assertEqual(session.transcribe(first), "Bonjour Julien.")
        self.assertEqual(session.transcribe(second), "Bonjour Julien. Je reviens.")
        np.testing.assert_array_equal(model.calls[1], np.concatenate((first[-2 * d.SAMPLE_RATE:], second)))
        self.assertEqual(session._audio_context.size, 2 * d.SAMPLE_RATE)

    def test_single_token_crossing_boundary_is_not_lost_or_duplicated(self):
        model = self.model([
            [(1, "Une", 0.0, 0.3), (2, " archi", 2.8, 0.2)],
            [(2, " archi", 1.8, 0.25), (3, "tecture", 2.05, 0.25), (4, " simple.", 2.5, 0.4)],
        ])
        session = d.ParakeetSession(model)
        self.assertEqual(session.transcribe(np.ones(3 * d.SAMPLE_RATE, dtype=np.float32)), "Une archi")
        self.assertEqual(session.transcribe(np.ones(d.SAMPLE_RATE, dtype=np.float32)), "Une architecture simple.")

    def test_unmatched_overlap_returns_to_original_chunk_instead_of_losing_a_word(self):
        model = self.model([
            [(1, "Une", 0.0, 0.3), (2, " archi", 2.8, 0.2)],
            [(3, " architecture", 1.8, 0.5), (4, " simple.", 2.5, 0.4)],
            [(5, "tecture", 0.0, 0.3), (4, " simple.", 0.5, 0.4)],
        ])
        session = d.ParakeetSession(model)
        session.transcribe(np.ones(3 * d.SAMPLE_RATE, dtype=np.float32))
        self.assertEqual(session.transcribe(np.ones(d.SAMPLE_RATE, dtype=np.float32)), "Une architecture simple.")
        self.assertEqual(model.calls[-1].size, d.SAMPLE_RATE)
        self.assertEqual(session.context_retries, 1)

    def test_short_first_chunk_uses_its_real_duration_as_context(self):
        model = self.model([
            [(1, "Bonjour.", 0.1, 0.3)],
            [(1, "Bonjour.", 0.1, 0.3), (2, " Demain.", 1.1, 0.4)],
        ])
        session = d.ParakeetSession(model)
        first = np.ones(d.SAMPLE_RATE, dtype=np.float32)
        session.transcribe(first)
        self.assertEqual(session.transcribe(first), "Bonjour. Demain.")
        self.assertEqual(model.calls[-1].size, 2 * d.SAMPLE_RATE)
        self.assertEqual(session._tokens[-1].start, 1.1)

    def test_token_center_after_boundary_does_not_allow_a_lossy_sdk_join(self):
        model = self.model([
            [(1, "Une", 0.0, 0.3), (2, " archi", 2.95, 0.05)],
            [(2, " archi", 1.95, 0.3), (3, "tecture", 2.25, 0.2), (4, " simple.", 2.6, 0.2)],
            [(3, "tecture", 0.0, 0.2), (4, " simple.", 0.6, 0.2)],
        ])
        session = d.ParakeetSession(model)
        session.transcribe(np.ones(3 * d.SAMPLE_RATE, dtype=np.float32))
        self.assertEqual(session.transcribe(np.ones(d.SAMPLE_RATE, dtype=np.float32)),
                         "Une architecture simple.")
        self.assertEqual(session.context_retries, 1)

    def test_changed_wordpieces_can_revise_the_full_snapshot(self):
        model = self.model([
            [(1, "On", 0.1, 0.3), (2, " prépare", 1.2, 0.2),
             (3, " la", 1.5, 0.2), (4, " version.", 2.5, 0.3)],
            [(2, " prépare", 0.2, 0.2), (5, " une", 0.5, 0.2),
             (6, " version", 1.5, 0.3), (7, " demain.", 2.5, 0.3)],
        ])
        session = d.ParakeetSession(model)
        self.assertEqual(session.transcribe(np.ones(3 * d.SAMPLE_RATE, dtype=np.float32)),
                         "On prépare la version.")
        self.assertEqual(session.transcribe(np.ones(d.SAMPLE_RATE, dtype=np.float32)),
                         "On prépare une version demain.")

    def test_repeated_words_keep_distinct_timestamps(self):
        model = self.model([
            [(1, "Oui", 0.1, 0.2), (2, " oui", 1.5, 0.2)],
            [(2, " oui", 0.5, 0.2), (2, " oui", 2.2, 0.2), (3, " demain.", 2.5, 0.3)],
        ])
        session = d.ParakeetSession(model)
        session.transcribe(np.ones(3 * d.SAMPLE_RATE, dtype=np.float32))
        self.assertEqual(session.transcribe(np.ones(d.SAMPLE_RATE, dtype=np.float32)), "Oui oui oui demain.")

    def test_silence_never_retranscribes_previous_words(self):
        model = self.model([[(1, "Bonjour.", 0.1, 0.3)]])
        session = d.ParakeetSession(model)
        session.transcribe(np.ones(d.SAMPLE_RATE, dtype=np.float32))
        self.assertEqual(session.transcribe(np.zeros(0, dtype=np.float32)), "")
        self.assertEqual(session.transcribe(np.zeros(3 * d.SAMPLE_RATE, dtype=np.float32)), "")
        self.assertEqual(len(model.calls), 1)
        self.assertFalse(np.any(session._audio_context))
        self.assertEqual(session._audio_samples, 4 * d.SAMPLE_RATE)

    def test_context_is_private_to_each_dictation(self):
        model = self.model([[(1, "Bonjour.", 0.1, 0.3)], [(2, "Bonsoir.", 0.1, 0.3)]])
        d.ParakeetSession(model).transcribe(np.ones(3 * d.SAMPLE_RATE, dtype=np.float32))
        session = d.ParakeetSession(model)
        self.assertEqual(session.transcribe(np.ones(d.SAMPLE_RATE, dtype=np.float32)), "Bonsoir.")
        self.assertEqual(model.calls[-1].size, d.SAMPLE_RATE)


class RevisedPartialTests(unittest.IsolatedAsyncioTestCase):
    async def test_final_replaces_partial_instead_of_concatenating_it(self):
        class Session(d.MockSession):
            replaces_text = True

            def step(self, **kwargs):
                if self.closed:
                    self._done = True
                    return ["Une architecture simple."]
                if self.samples:
                    self.samples = 0
                    return ["Une archi"]
                return []

        class Engines(d.MockEngines):
            def create_session(self, hint=""):
                return Session()

        with tempfile.TemporaryDirectory() as tmp:
            service = d.DictationService(Engines(), d.Lexicon(Path(tmp) / "lexicon.db"))
            service.status = "ready"
            socket = WakeDuringAudioTests.Socket()
            conn = d.DictationConnection(service, socket)
            try:
                await conn.start({})
                conn.feed(np.ones(1600, dtype="<f4").tobytes())
                for _ in range(100):
                    if any(m["type"] == "partial" for m in socket.messages):
                        break
                    await asyncio.sleep(0.001)
                self.assertTrue(any(m.get("text") == "Une archi" for m in socket.messages))
                await conn.stop()
                final = next(m for m in socket.messages if m["type"] == "final")
                self.assertEqual(final["raw"], "Une architecture simple.")
            finally:
                await conn.reset()
                service.mlx.pool.shutdown(wait=True)


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

    def test_asr_hint_prefers_current_app_without_wrong_variants_or_private_context(self):
        hint = self.lex.transcription_hint("com.apple.mail")
        self.assertTrue(hint.startswith("Vocabulaire : Allauch, FacilAbo"))
        self.assertEqual(hint.count("FacilAbo"), 1)
        self.assertNotIn("facil a beau", hint)
        self.assertNotIn("rendez-vous", hint)


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
