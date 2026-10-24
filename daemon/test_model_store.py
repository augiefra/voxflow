"""Tests du téléchargement des modèles, sans réseau : python -m unittest test_model_store

Un faux Hugging Face local sert un petit modèle ; il peut couper la connexion en plein
fichier ou ignorer l'en-tête Range."""

import errno
import hashlib
import http.server
import json
import os
import ssl
import urllib.error
import tempfile
import threading
import unittest
from pathlib import Path

import model_store as ms

PAYLOAD = os.urandom(3_000_000)
SHA = hashlib.sha256(PAYLOAD).hexdigest()
STATE = {"hits": 0, "mode": "normal", "ranges": []}


class FakeHub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if "/tree/" in self.path:
            body = json.dumps([
                {"type": "file", "path": "model.safetensors", "size": 134, "lfs": {"oid": SHA, "size": len(PAYLOAD)}},
                {"type": "file", "path": "config.json", "size": 2},
                {"type": "file", "path": "README.md", "size": 5},
            ]).encode()
        elif self.path.endswith("config.json"):
            body = b"{}"
        elif self.path.endswith("model.safetensors"):
            STATE["hits"] += 1
            rng = self.headers.get("Range")
            STATE["ranges"].append(rng)
            if rng and STATE["mode"] == "416":
                self.send_error(416)
                return
            start = int(rng.split("=")[1].rstrip("-")) if rng else 0
            honor = STATE["mode"] != "ignore_range"
            data = PAYLOAD[start:] if (rng and honor) else PAYLOAD
            self.send_response(206 if (rng and honor) else 200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if STATE["mode"] == "cut" and STATE["hits"] == 1:
                self.wfile.write(data[:1_200_000])
                self.wfile.flush()
                self.connection.shutdown(2)
                return
            self.wfile.write(data)
            return
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class NotFoundHub(FakeHub):
    def do_GET(self):
        self.send_error(404)


def serve(handler) -> http.server.ThreadingHTTPServer:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


SPEC = ms.ModelSpec("asr", "test/mini-model", "mini", ("*.json", "*.safetensors"), ("config.json",),
                    "a" * 40, len(PAYLOAD) + 2)


class ModelStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hub = serve(FakeHub)
        cls.missing = serve(NotFoundHub)

    @classmethod
    def tearDownClass(cls):
        cls.hub.shutdown()
        cls.missing.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self._saved = (ms.MODELS_DIR, ms.HF_ENDPOINT, ms._fetch, os.environ.get("HF_HUB_CACHE"))
        ms.MODELS_DIR = Path(self.tmp.name) / "models"
        ms.HF_ENDPOINT = f"http://127.0.0.1:{self.hub.server_port}"
        os.environ["HF_HUB_CACHE"] = str(Path(self.tmp.name) / "hf")   # jamais le vrai cache
        STATE.update(hits=0, mode="normal", ranges=[])
        self.naps = []

    def tearDown(self):
        ms.MODELS_DIR, ms.HF_ENDPOINT, ms._fetch, hub_cache = self._saved
        if hub_cache is None:
            os.environ.pop("HF_HUB_CACHE", None)
        else:
            os.environ["HF_HUB_CACHE"] = hub_cache
        self.tmp.cleanup()

    def progress(self):
        return ms.Progress(["asr"])

    def assert_complete(self, path: Path):
        self.assertEqual(hashlib.sha256((path / "model.safetensors").read_bytes()).hexdigest(), SHA)
        self.assertTrue(ms.is_ready(SPEC))

    def test_download_then_ready_offline(self):
        progress = self.progress()
        path = ms.ensure_model(SPEC, progress, sleep=self.naps.append)
        self.assert_complete(path)
        self.assertFalse((path / "README.md").exists())
        snap = progress.snapshot()
        self.assertEqual((snap["bytes_done"], snap["bytes_total"]), (len(PAYLOAD) + 2, len(PAYLOAD) + 2))
        self.assertEqual(snap["models"][0]["state"], "ready")
        # Relance sans Hub : prêt sans aucune requête.
        ms.HF_ENDPOINT = "http://127.0.0.1:9"
        self.assertEqual(ms.ensure_model(SPEC, self.progress()), path)

    def test_resumes_after_cut(self):
        STATE["mode"] = "cut"
        progress = self.progress()
        path = ms.ensure_model(SPEC, progress, sleep=self.naps.append)
        self.assert_complete(path)
        self.assertEqual(STATE["hits"], 2)
        self.assertEqual(self.naps, [2])
        self.assertEqual(progress.snapshot()["bytes_done"], len(PAYLOAD) + 2)

    def test_server_ignoring_range_restarts_file(self):
        STATE["mode"] = "ignore_range"
        folder = ms.MODELS_DIR / SPEC.dirname
        folder.mkdir(parents=True)
        (folder / "model.safetensors.part").write_bytes(PAYLOAD[:500_000])
        progress = self.progress()
        self.assert_complete(ms.ensure_model(SPEC, progress, sleep=self.naps.append))
        self.assertEqual(progress.snapshot()["bytes_done"], len(PAYLOAD) + 2)

    def test_corrupt_part_is_redownloaded(self):
        folder = ms.MODELS_DIR / SPEC.dirname
        folder.mkdir(parents=True)
        (folder / "model.safetensors.part").write_bytes(b"x" * len(PAYLOAD))
        self.assert_complete(ms.ensure_model(SPEC, self.progress(), sleep=self.naps.append))
        self.assertEqual(self.naps, [2])

    def test_not_enough_disk_fails_before_download(self):
        progress = self.progress()
        self.assertIsNone(progress.snapshot()["disk_needed_bytes"])   # rien de mesuré
        with self.assertRaises(ms.SetupError) as ctx:
            ms.ensure_model(SPEC, progress, free_bytes=1000)
        self.assertEqual(ctx.exception.code, "disk_full")
        self.assertTrue(ctx.exception.retryable)
        self.assertEqual(STATE["hits"], 0)
        progress.update(phase="error", error=ctx.exception)
        snap = progress.snapshot()
        self.assertGreater(snap["disk_needed_bytes"], len(PAYLOAD))
        self.assertEqual(snap["disk_free_bytes"], 1000)

    def test_full_mode_checks_disk_once_for_both_models(self):
        progress = ms.Progress(["asr", "llm"])
        with self.assertRaises(ms.SetupError) as ctx:
            ms.ensure_models(["asr", "llm"], progress, free_bytes=4 * 1024**3)   # assez pour Voxtral seul
        self.assertEqual(ctx.exception.code, "disk_full")
        self.assertGreaterEqual(ctx.exception.extra["needed_bytes"], ms.ASR.size + ms.LLM.size)
        self.assertFalse((ms.MODELS_DIR / ms.ASR.dirname).exists())   # rien téléchargé

    def test_disk_full_and_unknown_are_not_retried(self):
        for exc, code in ((OSError(errno.ENOSPC, "No space left on device"), "disk_full"),
                          (PermissionError(13, "Permission denied"), "unknown")):
            def fail(*_a, exc=exc, **_k):
                raise exc
            ms._fetch = fail
            self.naps = []
            with self.assertRaises(ms.SetupError) as ctx:
                ms.ensure_model(SPEC, self.progress(), sleep=self.naps.append)
            self.assertEqual(ctx.exception.code, code)
            self.assertEqual(self.naps, [])

    def test_disk_full_while_writing_reports_measures(self):
        def fail(*_a, **_k):
            raise OSError(errno.ENOSPC, "No space left on device")
        ms._fetch = fail
        with self.assertRaises(ms.SetupError) as ctx:
            ms.ensure_model(SPEC, self.progress(), sleep=self.naps.append)
        self.assertEqual(ctx.exception.code, "disk_full")
        self.assertGreater(ctx.exception.extra["needed_bytes"], len(PAYLOAD))
        self.assertIsInstance(ctx.exception.extra["free_bytes"], int)

    def test_server_refusing_resume_restarts_file(self):
        STATE["mode"] = "416"
        folder = ms.MODELS_DIR / SPEC.dirname
        folder.mkdir(parents=True)
        (folder / "model.safetensors.part").write_bytes(PAYLOAD[:500_000])
        progress = self.progress()
        self.assert_complete(ms.ensure_model(SPEC, progress, sleep=self.naps.append))
        self.assertEqual(STATE["ranges"], ["bytes=500000-", None])
        self.assertEqual(progress.snapshot()["bytes_done"], len(PAYLOAD) + 2)
        self.assertEqual(self.naps, [])

    def test_oversized_part_is_not_counted_twice(self):
        folder = ms.MODELS_DIR / SPEC.dirname
        folder.mkdir(parents=True)
        (folder / "model.safetensors.part").write_bytes(b"x" * (len(PAYLOAD) + 1000))
        progress = self.progress()
        self.assert_complete(ms.ensure_model(SPEC, progress, sleep=self.naps.append))
        self.assertEqual(progress.snapshot()["bytes_done"], len(PAYLOAD) + 2)

    def test_new_revision_is_applied_and_old_parts_dropped(self):
        path = ms.ensure_model(SPEC, self.progress(), sleep=self.naps.append)
        newer = ms.ModelSpec(SPEC.key, SPEC.repo, SPEC.label, SPEC.patterns, SPEC.required, "b" * 40, SPEC.size)
        self.assertTrue(ms.is_ready(SPEC))
        self.assertFalse(ms.is_ready(newer))
        # Même contenu côté Hub : le gros fichier, vérifié par SHA-256, n'est pas retéléchargé.
        hits = STATE["hits"]
        self.assertEqual(ms.ensure_model(newer, self.progress(), sleep=self.naps.append), path)
        self.assertEqual(STATE["hits"], hits)
        self.assertTrue(ms.is_ready(newer))
        # Un .part d'une révision précédente n'est jamais recollé.
        (path / "model.safetensors").unlink()
        (path / ms.MANIFEST).unlink()
        (path / "model.safetensors.part").write_bytes(b"x" * 500_000)
        STATE["ranges"] = []
        self.assert_complete(ms.ensure_model(SPEC, self.progress(), sleep=self.naps.append))
        self.assertEqual(STATE["ranges"], [None])
        self.assertEqual(self.naps, [])

    def test_old_revision_kept_when_hub_unreachable(self):
        path = ms.ensure_model(SPEC, self.progress(), sleep=self.naps.append)
        newer = ms.ModelSpec(SPEC.key, SPEC.repo, SPEC.label, SPEC.patterns, SPEC.required, "b" * 40, SPEC.size)
        ms.HF_ENDPOINT = "http://127.0.0.1:9"
        self.assertEqual(ms.ensure_model(newer, self.progress(), sleep=self.naps.append), path)

    def test_legacy_cache_prefers_frozen_revision_and_can_be_refused(self):
        repo = Path(os.environ["HF_HUB_CACHE"]) / ("models--" + SPEC.repo.replace("/", "--"))
        for name in ("c" * 40, SPEC.revision):
            for f in SPEC.required:
                (repo / "snapshots" / name).mkdir(parents=True, exist_ok=True)
                (repo / "snapshots" / name / f).write_text("{}")
        (repo / "refs").mkdir()
        (repo / "refs" / "main").write_text("c" * 40)
        self.assertEqual(ms.legacy_hf_snapshot(SPEC).name, SPEC.revision)
        for f in SPEC.required:
            (repo / "snapshots" / SPEC.revision / f).unlink()
        found = ms.legacy_hf_snapshot(SPEC)
        self.assertEqual(found.name, "c" * 40)   # 0.1.0 : refs/main, sans révision figée
        self.assertTrue(ms.is_legacy(found))
        self.assertFalse(ms.is_legacy(SPEC.path))
        ms.refuse_legacy(SPEC.key)
        self.assertIsNone(ms.legacy_hf_snapshot(SPEC))

    def test_no_network(self):
        ms.HF_ENDPOINT = "http://127.0.0.1:9"
        progress = self.progress()
        with self.assertRaises(ms.SetupError) as ctx:
            ms.ensure_model(SPEC, progress, sleep=lambda s: (self.naps.append(s), self.naps.append(progress.snapshot()["retry"])))
        self.assertEqual(ctx.exception.code, "network")
        self.assertTrue(ctx.exception.retryable)
        self.assertEqual(self.naps[0], 2)
        self.assertEqual(self.naps[1]["code"], "network")

    def test_unknown_host(self):
        ms.HF_ENDPOINT = "http://hub-introuvable.invalid"
        with self.assertRaises(ms.SetupError) as ctx:
            ms.ensure_model(SPEC, self.progress(), sleep=self.naps.append)
        self.assertEqual(ctx.exception.code, "network")

    def test_missing_repo_is_not_retried(self):
        ms.HF_ENDPOINT = f"http://127.0.0.1:{self.missing.server_port}"
        with self.assertRaises(ms.SetupError) as ctx:
            ms.ensure_model(SPEC, self.progress(), sleep=self.naps.append)
        self.assertEqual(ctx.exception.code, "hub_refused")
        self.assertFalse(ctx.exception.retryable)
        self.assertEqual(self.naps, [])

    def test_machine_checks(self):
        with self.assertRaises(ms.SetupError) as ctx:
            ms.check_machine(light=False, arm64=False)
        self.assertEqual(ctx.exception.code, "unsupported_cpu")
        with self.assertRaises(ms.SetupError) as ctx:
            ms.check_machine(light=False, arm64=True, memory_bytes=8 * 1024**3)
        self.assertEqual(ctx.exception.code, "low_memory")
        self.assertTrue(ctx.exception.extra["light_possible"])
        ms.check_machine(light=True, arm64=True, memory_bytes=8 * 1024**3)
        with self.assertRaises(ms.SetupError):
            ms.check_machine(light=True, arm64=True, memory_bytes=4 * 1024**3)

    def test_local_errors_are_not_network_errors(self):
        self.assertEqual(ms.classify(FileNotFoundError(2, "No such file or directory", "sysctl")).code, "unknown")
        self.assertEqual(ms.classify(ConnectionResetError()).code, "network")
        self.assertEqual(ms.classify(OSError(28, "No space left on device")).code, "disk_full")

    def test_tls_errors(self):
        bad_cert = ssl.SSLCertVerificationError(1, "certificate verify failed: unable to get local issuer")
        for exc in (bad_cert, urllib.error.URLError(bad_cert)):
            err = ms.classify(exc)
            self.assertEqual((err.code, err.retryable), ("tls", False))
        self.assertEqual(ms.classify(ssl.SSLEOFError(8, "EOF occurred in violation of protocol")).code, "network")
        self.assertEqual(ms.classify(urllib.error.URLError(ssl.SSLError(1, "bad record mac"))).code, "network")

    def test_free_space_counts_purgeable_space_from_app(self):
        real = ms.shutil.disk_usage(self.tmp.name).free
        os.environ["VOXFLOW_DISK_AVAILABLE"] = str(real + 10**12)
        try:
            self.assertEqual(ms.free_space(Path(self.tmp.name)), real + 10**12)
            os.environ["VOXFLOW_DISK_AVAILABLE"] = "pas un nombre"
            self.assertLessEqual(abs(ms.free_space(Path(self.tmp.name)) - real), 1 << 30)
        finally:
            os.environ.pop("VOXFLOW_DISK_AVAILABLE", None)

    def test_snapshot_contract(self):
        progress = ms.Progress(["asr", "llm"])
        snap = progress.snapshot()
        for key in ("status", "error", "phase", "bytes_done", "bytes_total", "models", "error_code", "retryable", "retry"):
            self.assertIn(key, snap)
        self.assertEqual(snap["status"], "loading")
        # Les totaux sont connus d'avance : la barre ne recule pas au second modèle.
        self.assertEqual(snap["bytes_total"], ms.ASR.size + ms.LLM.size)
        progress.update(phase="error", error=ms.SetupError("network", "x", retryable=True))
        snap = progress.snapshot()
        self.assertEqual((snap["status"], snap["error_code"], snap["retryable"]), ("error", "network", True))
        self.assertIsNone(snap["disk_free_bytes"])
        self.assertIsNone(snap["disk_needed_bytes"])


if __name__ == "__main__":
    unittest.main()
