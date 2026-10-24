"""Téléchargement des modèles VoxFlow avec progression en octets, reprise après coupure
(Range + .part), vérification SHA-256, contrôle d'espace disque et de machine.

Bibliothèque standard uniquement : importable avant mlx, et sans la reprise défaillante de
huggingface_hub (un .incomplete par coupure, fichier entier à refaire). Les révisions sont
figées comme uv.lock fige les dépendances : tous les utilisateurs ont les mêmes poids."""

from __future__ import annotations

import errno
import fcntl
import hashlib
import http.client
import json
import os
import platform
import shutil
import socket
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from fnmatch import fnmatch
from pathlib import Path

HF_ENDPOINT = os.environ.get("HF_ENDPOINT", "https://huggingface.co").rstrip("/")
MODELS_DIR = Path(os.environ.get("VOXFLOW_MODELS_DIR")
                  or Path(os.environ.get("VOXFLOW_DATA_DIR") or Path.home() / ".voxflow") / "models")
USER_AGENT = "VoxFlow-model-store/1"
DISK_MARGIN = 1 * 1024**3  # on garde 1 Gio de libre après le téléchargement
MANIFEST = ".voxflow-complete.json"
# Révision en cours de téléchargement : les .part d'une autre révision ne sont jamais recollés.
REVISION_FILE = ".voxflow-revision"
# Seules ces erreurs sont retentées automatiquement ; les autres attendent « Réessayer ».
AUTO_RETRY = {"network", "hub_unavailable", "integrity"}

# Mêmes motifs que mlx_audio.utils.DEFAULT_ALLOW_PATTERNS et mlx_lm.utils.DEFAULT_ALLOW_PATTERNS.
ASR_PATTERNS = ("*.json", "*.safetensors", "*.py", "*.model", "*.tiktoken", "*.txt", "*.jinja",
                "*.jsonl", "*.yaml", "*.npz", "*.pth")
LLM_PATTERNS = ("*.json", "model*.safetensors", "*.py", "tokenizer.model", "*.tiktoken",
                "tiktoken.model", "*.txt", "*.jsonl", "*.jinja")


@dataclass(frozen=True)
class ModelSpec:
    key: str                       # "asr" | "llm"
    repo: str
    label: str
    patterns: tuple[str, ...]
    required: tuple[str, ...]      # fichiers sans lesquels un dossier hérité n'est pas utilisable
    revision: str                  # commit figé du dépôt Hugging Face
    size: int                      # octets attendus (fichiers retenus par `patterns`), pour la barre

    @property
    def dirname(self) -> str:      # même nom que le dépôt : mlx-audio devine la famille d'après le nom
        return self.repo.split("/")[-1]

    @property
    def path(self) -> Path:
        return MODELS_DIR / self.dirname


ASR = ModelSpec("asr", "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
                "Voxtral Mini 4B (transcription)", ASR_PATTERNS,
                ("config.json", "model.safetensors", "tekken.json"),
                "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e", 3_148_828_619)
LLM = ModelSpec("llm", "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                "Qwen2.5 Coder 7B (nettoyage du texte)", LLM_PATTERNS,
                ("config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"),
                "019cc73c45c770444708a6dd8690c66243cc5c80", 4_295_887_638)
SPECS = {s.key: s for s in (ASR, LLM)}


class SetupError(Exception):
    """Erreur affichable : `code` est stable (le client Swift choisit le texte et le bouton)."""

    def __init__(self, code: str, message: str, *, retryable: bool = False, **extra) -> None:
        super().__init__(message)
        self.code, self.message, self.retryable, self.extra = code, message, retryable, extra


# --------------------------------------------------------------------------- progression


class Progress:
    """État partagé entre le thread de téléchargement et /health (tout sous verrou)."""

    def __init__(self, keys: list[str]) -> None:
        self._lock = threading.Lock()
        self.phase = "checking"           # checking | downloading | loading | warmup | ready | error
        self.model: str | None = None
        self.file: str | None = None
        # Total connu d'avance : la barre ne recule pas quand le second modèle commence.
        self.models = {k: {"id": k, "state": "pending", "done": 0, "total": SPECS[k].size if k in SPECS else 0}
                       for k in keys}
        self.error: SetupError | None = None
        self.retry: dict | None = None
        self._samples: list[tuple[float, int]] = []

    def update(self, **fields) -> None:
        with self._lock:
            for k, v in fields.items():
                setattr(self, k, v)

    def set_model(self, key: str, **fields) -> None:
        with self._lock:
            self.models[key].update(fields)

    def add_bytes(self, key: str, n: int) -> None:
        with self._lock:
            self.models[key]["done"] += n
            now = time.monotonic()
            self._samples.append((now, n))
            while self._samples and now - self._samples[0][0] > 6:
                self._samples.pop(0)

    def snapshot(self) -> dict:
        """Contrat /health. `status` et `error` restent ceux que lit InferenceClient.health."""
        with self._lock:
            done = sum(m["done"] for m in self.models.values())
            total = sum(m["total"] for m in self.models.values())
            window = (time.monotonic() - self._samples[0][0]) if self._samples else 0
            speed = int(sum(n for _, n in self._samples) / window) if window >= 1 else 0
            err = self.error
            status = "error" if self.phase == "error" else "ready" if self.phase == "ready" else "loading"
            return {
                "status": status,
                "error": err.message if err else "",
                "phase": self.phase,
                "model": self.model,
                "file": self.file,
                "bytes_done": done,
                "bytes_total": total,
                "speed_bps": speed if self.phase == "downloading" else 0,
                "eta_s": int((total - done) / speed) if speed and self.phase == "downloading" else None,
                "models": [dict(m) for m in self.models.values()],
                "error_code": err.code if err else None,
                "retryable": err.retryable if err else None,
                # Mesures de l'erreur en cours seulement (null si rien n'a été mesuré).
                "disk_free_bytes": err.extra.get("free_bytes") if err else None,
                "disk_needed_bytes": err.extra.get("needed_bytes") if err else None,
                "retry": self.retry,   # {"code","attempt","in_s"} pendant une attente avant nouvel essai
            }


# --------------------------------------------------------------------------- contrôles machine


def check_machine(*, light: bool, memory_bytes: int | None = None, arm64: bool | None = None) -> None:
    if arm64 is None:
        # hw.optional.arm64 vaut 1 sur Apple Silicon même sous Rosetta ; platform.machine() mentirait.
        try:
            out = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True)
            arm64 = out.stdout.strip() == "1"
        except OSError:
            arm64 = False
        arm64 = arm64 or platform.machine() == "arm64"
    if not arm64:
        raise SetupError("unsupported_cpu", "VoxFlow demande un Mac Apple Silicon (M1 ou plus récent).")
    if memory_bytes is None:
        memory_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    gib = memory_bytes / 1024**3
    need = 8 if light else 16   # hypothèse de seuil, voir le rapport : non mesurée sur Mac 8 Go / 16 Go
    if gib < need - 0.5:
        raise SetupError("low_memory",
                         f"{gib:.0f} Go de mémoire : le mode complet demande {need} Go minimum. "
                         "Le mode léger (sans nettoyage par IA) reste possible." if not light else
                         f"{gib:.0f} Go de mémoire : VoxFlow demande {need} Go minimum.",
                         memory_bytes=memory_bytes, light_possible=not light and gib >= 8 - 0.5)


def free_space(path: Path) -> int:
    """Octets libres. statfs ignore l'espace purgeable d'APFS que le Finder compte : l'app
    transmet volumeAvailableCapacityForImportantUsage dans VOXFLOW_DISK_AVAILABLE."""
    free = shutil.disk_usage(path).free
    try:
        return max(free, int(os.environ.get("VOXFLOW_DISK_AVAILABLE", "0")))
    except ValueError:
        return free


# --------------------------------------------------------------------------- plan et téléchargement


def _get_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def classify(exc: BaseException) -> SetupError:
    if isinstance(exc, SetupError):
        return exc
    if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
        extra = {}
        try:
            extra["free_bytes"] = free_space(MODELS_DIR)
        except OSError:
            pass
        return SetupError("disk_full", "Disque plein : libère de la place puis relance.", retryable=True, **extra)
    if isinstance(exc, urllib.error.HTTPError):
        if exc.code in (401, 403, 404):
            return SetupError("hub_refused", f"Hugging Face refuse l'accès (HTTP {exc.code}).")
        return SetupError("hub_unavailable", f"Hugging Face est indisponible (HTTP {exc.code}).", retryable=True)
    reason = exc.reason if isinstance(exc, urllib.error.URLError) else exc
    if isinstance(reason, ssl.SSLCertVerificationError):
        # Proxy d'entreprise ou antivirus qui inspecte le trafic : réessayer n'y changera rien.
        return SetupError("tls", "Certificat de Hugging Face non reconnu : un proxy ou un antivirus inspecte "
                          "peut-être les connexions.")
    if isinstance(reason, ssl.SSLError):   # SSLEOFError en changeant de Wi-Fi…
        return SetupError("network", "Connexion interrompue. Le téléchargement reprendra là où il s'est arrêté.",
                          retryable=True)
    if isinstance(exc, RuntimeError) and ("memory" in str(exc).lower() or "malloc" in str(exc)):
        return SetupError("low_memory", "Mémoire insuffisante pour charger les modèles. Le mode léger demande moins de mémoire.")  # heuristique non testée
    if isinstance(exc, http.client.HTTPException):   # IncompleteRead, RemoteDisconnected…
        return SetupError("network", "Connexion interrompue. Le téléchargement reprendra là où il s'est arrêté.", retryable=True)
    # Une URLError enveloppe toujours un échec de connexion ; un autre OSError (fichier
    # absent, droits) n'est pas un problème de réseau.
    if isinstance(exc, (urllib.error.URLError, socket.gaierror, socket.timeout, TimeoutError, ConnectionError)):
        return SetupError("network", "Pas de connexion à Internet. Le téléchargement reprendra là où il s'est arrêté.",
                          retryable=True)
    return SetupError("unknown", f"{type(exc).__name__}: {exc}", retryable=True)


def plan(spec: ModelSpec) -> dict:
    """Liste des fichiers de la révision figée (taille, SHA-256 des fichiers LFS)."""
    rev = spec.revision
    tree = _get_json(f"{HF_ENDPOINT}/api/models/{spec.repo}/tree/{rev}?recursive=true")  # <1000 entrées ici
    files = []
    for e in tree:
        if e["type"] != "file" or not any(fnmatch(e["path"], p) for p in spec.patterns):
            continue
        lfs = e.get("lfs")
        files.append({"path": e["path"], "size": lfs["size"] if lfs else e["size"],
                      "sha256": lfs["oid"] if lfs else None})
    return {"repo": spec.repo, "revision": rev, "files": files}


def _complete(spec: ModelSpec) -> dict | None:
    """Manifeste d'un dossier complet (quelle que soit sa révision), sinon None. Hors ligne."""
    try:
        manifest = json.loads((spec.path / MANIFEST).read_text())
        if all((spec.path / f["path"]).stat().st_size == f["size"] for f in manifest["files"]):
            return manifest
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def is_ready(spec: ModelSpec) -> bool:
    """Vérification hors ligne et instantanée (aucun appel réseau) : dossier complet, à la
    révision figée. Une montée de révision refait donc le téléchargement."""
    manifest = _complete(spec)
    return manifest is not None and manifest.get("revision") == spec.revision


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def _part_size(dest: Path) -> int:
    try:
        return dest.with_name(dest.name + ".part").stat().st_size
    except OSError:
        return 0


def _fetch(url: str, dest: Path, size: int, sha256: str | None, on_bytes) -> None:
    """La progression compte toujours min(taille du .part, size) pour ce fichier : chaque
    changement du .part passe par `credit`, et bytes_done ne dépasse jamais bytes_total."""
    part = dest.with_name(dest.name + ".part")
    dest.parent.mkdir(parents=True, exist_ok=True)

    def credit(old: int, new: int) -> None:
        on_bytes(min(new, size) - min(old, size))

    have = part.stat().st_size if part.exists() else 0
    if have > size:
        credit(have, 0)
        part.unlink()
        have = 0
    for _ in range(2):
        if have >= size:
            break
        headers = {"User-Agent": USER_AGENT}
        if have:
            headers["Range"] = f"bytes={have}-"
        try:
            resp = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30)
        except urllib.error.HTTPError as e:
            if e.code == 416 and have:  # le serveur refuse la reprise : on repart de zéro
                credit(have, 0)
                part.unlink(missing_ok=True)
                have = 0
                continue
            raise
        with resp:
            if have and resp.status != 206:     # Range ignoré : on repart de zéro
                credit(have, 0)
                have = 0
            with open(part, "ab" if have else "wb") as f:
                while chunk := resp.read(1 << 20):
                    f.write(chunk)
                    credit(have, have + len(chunk))
                    have += len(chunk)
        break
    if not part.exists() or part.stat().st_size != size:
        raise SetupError("network", "Téléchargement interrompu.", retryable=True)
    if sha256 and _sha256(part) != sha256:
        credit(size, 0)
        part.unlink()
        raise SetupError("integrity", "Fichier corrompu (empreinte invalide) : nouveau téléchargement.",
                         retryable=True)
    os.replace(part, dest)


def _wait(progress: Progress, err: SetupError, attempt: int, sleep) -> None:
    delay = min(30, 2 ** attempt)
    progress.update(retry={"code": err.code, "attempt": attempt, "in_s": delay})
    sleep(delay)
    progress.update(retry=None)


def ensure_model(spec: ModelSpec, progress: Progress, *, free_bytes: int | None = None,
                 max_attempts: int = 6, plan_attempts: int = 3, sleep=time.sleep) -> Path:
    """Télécharge `spec` dans ~/.voxflow/models/<nom> si besoin et renvoie le dossier."""
    if is_ready(spec):
        size = sum(f["size"] for f in json.loads((spec.path / MANIFEST).read_text())["files"])
        progress.set_model(spec.key, state="ready", done=size, total=size)
        return spec.path

    last: SetupError | None = None
    progress.update(phase="checking")      # on échoue vite (~6 s) si le Hub est injoignable
    for attempt in range(1, plan_attempts + 1):
        try:
            pl = plan(spec)
            break
        except Exception as exc:  # noqa: BLE001
            last = classify(exc)
            if last.code not in AUTO_RETRY or attempt == plan_attempts:
                old = _complete(spec)
                if old is not None and last.code in ("network", "hub_unavailable", "tls"):
                    # Nouvelle révision injoignable : on garde l'ancienne, complète, pour dicter.
                    size = sum(f["size"] for f in old["files"])
                    progress.set_model(spec.key, state="ready", done=size, total=size)
                    return spec.path
                raise last from exc
            _wait(progress, last, attempt, sleep)
    else:
        raise last  # pragma: no cover

    wanted = {f["path"] for f in pl["files"]}
    spec.path.mkdir(parents=True, exist_ok=True)
    stamp = spec.path / REVISION_FILE
    try:
        previous = stamp.read_text().strip()
    except OSError:
        previous = None
    if previous is None:
        old = _complete(spec)
        previous = old.get("revision") if old else None
    stale = previous is not None and previous != pl["revision"]
    # Fichiers d'une ancienne révision : on les supprime avant de compter l'espace. Après une
    # montée de révision, les .part et les fichiers sans empreinte sont tous refaits ; un gros
    # fichier déjà complet n'est gardé que si son SHA-256 correspond.
    sha = {f["path"]: f["sha256"] for f in pl["files"]}
    for p in list(spec.path.rglob("*")):
        if not p.is_file() or p.name in (MANIFEST, REVISION_FILE, ".lock"):
            continue
        rel = str(p.relative_to(spec.path))
        if rel.removesuffix(".part") not in wanted:
            p.unlink()
        elif stale and (p.name.endswith(".part") or not sha[rel] or _sha256(p) != sha[rel]):
            p.unlink()
    (spec.path / MANIFEST).unlink(missing_ok=True)
    stamp.write_text(pl["revision"])

    total = sum(f["size"] for f in pl["files"])
    have = sum(f["size"] if (spec.path / f["path"]).exists() and (spec.path / f["path"]).stat().st_size == f["size"]
               else min(_part_size(spec.path / f["path"]), f["size"]) for f in pl["files"])
    needed = total - have
    free = free_space(spec.path) if free_bytes is None else free_bytes
    if free < needed + DISK_MARGIN:
        raise SetupError("disk_full",
                         f"Il faut {(needed + DISK_MARGIN) / 1e9:.1f} Go libres, {free / 1e9:.1f} Go disponibles.",
                         retryable=True, needed_bytes=needed + DISK_MARGIN, free_bytes=free)

    progress.set_model(spec.key, state="downloading", done=have, total=total)
    progress.update(model=spec.key, phase="downloading")
    # Les gros fichiers d'abord, pour que la barre avance vite ; les petits sont quasi instantanés.
    for f in sorted(pl["files"], key=lambda f: -f["size"]):
        dest = spec.path / f["path"]
        if dest.exists() and dest.stat().st_size == f["size"]:
            continue
        url = f"{HF_ENDPOINT}/{spec.repo}/resolve/{pl['revision']}/{f['path']}"
        progress.update(file=f["path"])
        for attempt in range(1, max_attempts + 1):
            before = _part_size(dest)
            counted = [0]

            def on_bytes(n: int) -> None:
                counted[0] += n
                progress.add_bytes(spec.key, n)

            try:
                _fetch(url, dest, f["size"], f["sha256"], on_bytes)
                break
            except Exception as exc:  # noqa: BLE001
                err = classify(exc)
                if err.code == "disk_full" and "needed_bytes" not in err.extra:
                    left = sum(g["size"] - min(_part_size(spec.path / g["path"]), g["size"])
                               for g in pl["files"] if not (spec.path / g["path"]).exists())
                    err.extra["needed_bytes"] = left + DISK_MARGIN
                if err.code not in AUTO_RETRY or attempt == max_attempts:
                    raise err from exc
                _wait(progress, err, attempt, sleep)
    (spec.path / MANIFEST).write_text(json.dumps(pl))
    progress.set_model(spec.key, state="ready", done=total, total=total)
    return spec.path


def _refused_marker(spec: ModelSpec) -> Path:
    return MODELS_DIR / f".hf-cache-refused-{spec.key}"


def refuse_legacy(key: str) -> None:
    """Le cache Hugging Face n'a pas pu être chargé : on télécharge au prochain essai."""
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    _refused_marker(SPECS[key]).write_text("chargement impossible depuis le cache Hugging Face\n")


def is_legacy(path: Path | None) -> bool:
    return path is not None and MODELS_DIR not in Path(path).parents


def legacy_hf_snapshot(spec: ModelSpec) -> Path | None:
    """Réutilise un modèle déjà présent dans le cache Hugging Face (installations existantes,
    développeurs) sans le copier ni le retélécharger. Vérification hors ligne, sans réseau :
    d'abord la révision figée, sinon celle de refs/main (la 0.1.0 ne figeait rien)."""
    if _refused_marker(spec).exists():
        return None
    hub = Path(os.environ.get("HF_HUB_CACHE") or Path(os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface")) / "hub")
    repo_dir = hub / ("models--" + spec.repo.replace("/", "--"))
    names = [spec.revision]
    try:
        names.append((repo_dir / "refs" / "main").read_text().strip())
    except OSError:
        pass
    for name in names:
        snap = repo_dir / "snapshots" / name
        if name and all((snap / f).exists() for f in spec.required):
            return snap
    return None


def locate(spec: ModelSpec, progress: Progress) -> Path | None:
    """Dossier utilisable tout de suite (magasin VoxFlow, puis cache HF), sinon None."""
    for candidate in (spec.path if is_ready(spec) else None, legacy_hf_snapshot(spec)):
        if candidate is not None:
            size = sum(p.stat().st_size for p in candidate.iterdir() if p.is_file() and not p.name.startswith("."))
            progress.set_model(spec.key, state="ready", done=size, total=size)
            return candidate
    return None


def _bytes_on_disk(spec: ModelSpec) -> int:
    try:
        return sum(p.stat().st_size for p in spec.path.rglob("*") if p.is_file() and not p.name.startswith("."))
    except OSError:
        return 0


def check_disk(specs: list[ModelSpec], free_bytes: int | None = None) -> None:
    """Contrôle unique avant de commencer : en mode complet, le manque de place pour Qwen ne
    doit pas apparaître après les 3 Go de Voxtral. Estimation d'après les tailles figées ;
    ensure_model refait le compte exact, fichier par fichier, pour chaque modèle."""
    if not specs:
        return
    needed = sum(max(0, s.size - _bytes_on_disk(s)) for s in specs) + DISK_MARGIN
    free = free_space(MODELS_DIR) if free_bytes is None else free_bytes
    if free < needed:
        raise SetupError("disk_full", f"Il faut {needed / 1e9:.1f} Go libres, {free / 1e9:.1f} Go disponibles.",
                         retryable=True, needed_bytes=needed, free_bytes=free)


def ensure_models(keys: list[str], progress: Progress | None = None, **kw) -> tuple[Progress, dict[str, Path]]:
    """Modèles `keys` ("asr", "llm") prêts sur disque : magasin VoxFlow, cache HF, sinon téléchargement."""
    specs = [SPECS[k] for k in keys]
    progress = progress or Progress(keys)
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    with open(MODELS_DIR / ".lock", "w") as lock:        # un seul téléchargeur à la fois
        fcntl.flock(lock, fcntl.LOCK_EX)
        found = {s.key: locate(s, progress) for s in specs}
        check_disk([s for s in specs if found[s.key] is None], kw.get("free_bytes"))
        paths = {s.key: found[s.key] or ensure_model(s, progress, **kw) for s in specs}
    return progress, paths
