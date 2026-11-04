# VoxFlow — documentation technique (français)

Maintiens **Fn** (ou la touche choisie : ⌘, ⌥ ou ⌃ de droite) pour dicter, ou **appuie deux fois** pour dicter mains libres (un appui termine). Par défaut, **Parakeet TDT 0.6B v3** transcrit les segments audio et **Qwen3.5 4B** nettoie le texte si nécessaire, puis VoxFlow le colle au curseur. Le démon accepte aussi Whisper et Voxtral comme moteurs ASR via `--asr-model`. VoxFlow observe ensuite tes corrections pendant 25 s et apprend ton vocabulaire (« Allo » → « Allauch », « facil a beau » → « FacilAbo »).

Tout tourne en local : aucun audio ni texte ne quitte le Mac.

## Arborescence

```
VoxFlow/
├── README.md
├── LICENSE                              MIT
├── daemon/                              Démon Python MLX (WebSocket 127.0.0.1:8765)
│   ├── inference_daemon.py              Parakeet (segments) + Qwen3.5 (nettoyage) + dictionnaire SQLite
│   ├── model_store.py                   Téléchargement des modèles : reprise, SHA-256, progression (/health)
│   ├── test_inference_daemon.py         Tests sans modèles (--mock)
│   ├── test_model_store.py              Tests du téléchargement avec un faux Hugging Face local
│   ├── pyproject.toml                   mlx-audio[stt] ≥ 0.6.1, mlx-lm ≥ 0.32.2, websockets ≥ 14
│   └── uv.lock
└── macos/                               App Swift (barre de menu, LSUIElement)
    ├── Package.swift                    Dépendance : Sparkle 2.10 (mises à jour)
    ├── release.env.example              Adresses du flux et du dépôt de diffusion (à copier en release.env)
    ├── Resources/Info.plist             Version, copyright, clé publique Sparkle (langue de base : anglais)
    ├── Resources/{en,fr}.lproj          Textes de l'interface (Localizable.strings) et de l'Info.plist
    ├── Resources/VoxFlow.entitlements   Droit micro (runtime renforcé)
    ├── Resources/VoxFlow.icon           Icône Icon Composer (fond noir, vagues, point rouge ; compilée par actool)
    ├── Resources/THIRD_PARTY_NOTICES.txt  Crédits et licences (généré par make_notices.py)
    ├── scripts/build_app.sh             Build release + démon + uv + Sparkle + textes, signature runtime renforcé
    ├── scripts/fetch_uv.sh              Télécharge uv 0.12.24 (empreinte vérifiée) pour Contents/Helpers
    ├── scripts/release.sh               Developer ID, notarisation, DMG, appcast signé (ne publie rien)
    ├── scripts/publish_release.sh       Mise en ligne sur GitHub Releases
    ├── scripts/make_notices.py          Génère les licences tierces
    ├── scripts/update_appcast.py        Ajoute une version à l'appcast
    ├── Sources/VoxFlow/
    │   ├── main.swift
    │   ├── AppController.swift          Chef d'orchestre + menu (dont mises à jour Sparkle)
    │   ├── EngineController.swift       Préparation et suivi des moteurs (Python, démon, modèles)
    │   ├── OnboardingView.swift         Accueil en 5 pages (SwiftUI) et avancement des moteurs
    │   ├── SettingsView.swift           Réglages : touche, mode complet ou léger, revoir l'accueil
    │   ├── SnapshotDemo.swift           VoxFlow --snapshots <dossier> : pages rendues en PNG, hors écran
    │   ├── AboutPanel.swift             Fenêtre « À propos » et crédits (VoxFlow --about-demo)
    │   ├── AppLog.swift                 Journal ~/.voxflow/app.log (appuis Fn, durées)
    │   └── HUDDemo.swift                VoxFlow --hud-demo [ecoute|verrouille|traitement|appris]
    ├── Sources/VoxFlowCore/
    │   ├── FnKeyStateMachine.swift      Push-to-talk / double appui (machine à états + DictationKeyController)
    │   ├── DictationKey.swift           Touches Fn, ⌘/⌥/⌃ de droite ; réglages (UserDefaults) ; modes
    │   ├── DaemonManager.swift          uv embarqué, environnement Python, lancement du démon, /health
    │   ├── L10n.swift                   Textes français et anglais (Bundle.main)
    │   ├── GlobalEventTap.swift         Tap unique : touche de dictée, frappes de surveillance, clics
    │   ├── AccessibilityMonitor.swift   Collage, AXManualAccessibility, surveillance AX + buffer clavier
    │   ├── DiffLearner.swift            Alignement mot à mot, filtres, SQLite
    │   ├── AudioCapture.swift           AVAudioEngine → PCM Float32 16 kHz mono
    │   ├── InferenceClient.swift        Client WebSocket du démon
    │   ├── HUDPanel.swift               Pilule « Dynamic Island » à vagues (NSPanel non activable, .floating)
    │   ├── SystemAudioMuter.swift       Coupe le son du Mac pendant l'écoute
    │   └── VoxFlowPaths.swift           Dossier ~/.voxflow et reprise de l'ancien ~/.wispr_clone
    └── Tests/VoxFlowCoreTests/          62 tests XCTest (dont touches, /health, parité des langues)
```

## Chaîne de traitement

1. **Appui sur la touche** : avec Fn, l'enregistrement démarre aussitôt ; avec ⌘, ⌥ ou ⌃ de droite, le micro s'ouvre après 150 ms et l'écoute ne se montre (pilule, son coupé) qu'après 150 ms de plus, pour qu'un raccourci (⌘C, ⌥-clic…) ne déclenche rien. VoxFlow pose `AXManualAccessibility` sur l'app au premier plan, pour que VS Code, Cursor, Slack ou Chrome aient le temps d'exposer leurs champs. L'audio part au démon par blocs, pendant que tu parles.
2. **Démon** : l'audio arrive au démon pendant que tu parles. Avec Parakeet, aucun texte partiel n'est décodé pendant une émission de voix : le segment est transcrit après une pause franche d'au moins 400 ms, à condition qu'il contienne au moins 1,5 s d'audio. Sans pause, une coupure de secours intervient à 28 s, au point le plus calme repéré dans le segment. À l'arrêt, le reste du tampon est finalisé. Depuis la version 0.1.8, jusqu'à 2 s d'audio précédent sont conservées pour donner du contexte au morceau suivant. Les tokens horodatés sont fusionnés ; chaque résultat partiel est une version complète révisable, pas une portion à concaténer. Le tampon audio supplémentaire est borné à 128 000 octets. Quand le chevauchement n'a aucune ancre fiable, seule la nouvelle tranche est redécodée pour préserver le comportement précédent.
3. **Nettoyage** : le nettoyage démarre après la fin de la dictée, pas pendant que tu parles. « euh », « heu » et « hum » sont retirés localement. Qwen3.5 est appelé seulement si la transcription présente une hésitation ambiguë, une reprise ou une correction contextuelle à faire ; sinon, les corrections déterministes sûres du lexique et la typographie française suffisent. Les règles correspondantes du lexique sont ajoutées au prompt, avec des garde-fous sur le format et la longueur ; une sortie rejetée ou une échéance dépassée déclenche le nettoyage local de secours. Le budget de génération, partagé entre les segments d'une dictée, est de 1,5 s. L'interruption est vérifiée entre les tokens : une opération GPU déjà commencée peut finir après l'échéance. Le lexique fournit aussi à Whisper un prompt de reconnaissance limité à 12 termes et 240 caractères ; Parakeet ne prend pas de prompt textuel, donc ces termes ne guident pas directement son décodage.
4. **Collage** : sauvegarde du presse-papier, puis Cmd+V (touche « v » de ta disposition clavier, AZERTY compris), puis restauration après 150 ms. Les 5 dernières dictées restent en mémoire (jamais sur le disque) : menu « Dernières dictées », un clic les recolle dans le champ actif et les laisse dans le presse-papier.
5. **Surveillance (25 s, ou jusqu'au changement de focus, Entrée ou Cmd+Entrée)** :
   - méthode primaire : valeur `kAXValueAttribute` du champ, suivie par notifications `AXObserver` et relecture toutes les 300 ms ; à Entrée, le texte est capturé avant l'envoi ;
   - méthode de secours (Terminal, champs sans AX) : buffer d'ombre reconstruit à partir des frappes (effacement, flèches, Option et Cmd, Ctrl+A/E/W/U/K, Cmd+V/X, sélection Maj).
6. **Apprentissage** : alignement LCS mot à mot. Une réécriture de plus de 60 % de la phrase est ignorée. Ne sont retenues que les substitutions de 1 à 4 mots proches à l'orthographe ou à l'oreille (seuil 0,6). Sont exclus la grammaire (« est » → « et »), la majuscule de début de phrase et les champs mot de passe. Chaque règle va dans `~/.voxflow/lexicon.db`, et le HUD affiche « Appris : FacilAbo (au lieu de 'facil a beau') ».

Base SQLite (table imposée, plus un index unique pour compter les répétitions) :

```sql
CREATE TABLE lexicon (id INTEGER PRIMARY KEY, wrong_variant TEXT, canonical_term TEXT, context_hint TEXT,
                      app_bundle_id TEXT, frequency INTEGER DEFAULT 1, updated_at DATETIME);
CREATE UNIQUE INDEX idx_lexicon_pair ON lexicon(wrong_variant COLLATE NOCASE, canonical_term);
```

## Pilule et latence

Pilule noire en bas au centre, au-dessus du Dock :
- **Écoute** : point rouge, vagues blanches qui suivent ta voix, chrono.
- **Mains libres** : cadenas, vagues orange qui ondulent même en silence, chrono, stop.
- **Traitement** : « Mise en forme… ».
- **Toasts** : « Appris : … » et erreurs. Un « Appris » né pendant une dictée (surveillance close par la dictée suivante) s'affiche à la fin de celle-ci.

Pour le geste, un tap dure moins de 300 ms et le second tap doit arriver dans les 400 ms. Ces seuils ont été élargis par rapport aux 250 ms du cahier des charges, après l'essai réel.

Touches de droite : elles se reconnaissent au keyCode (54, 61, 62) et au bit « côté droit » que macOS pose dans `CGEventFlags.rawValue` (0x10, 0x40, 0x2000, d'après IOLLEvent.h) ; sans ces bits (clavier exotique), VoxFlow bascule l'état à chaque événement de la touche. Le tap reste en observation seule : un raccourci passe toujours à l'app. VoxFlow annule sa dictée sans rien montrer si une autre touche, un clic, un défilement (hors inertie) ou un autre modificateur arrive avant 300 ms ; après, la même entrée l'annule sans rien coller. Avec une touche de droite, un problème (moteurs pas prêts, micro refusé) ne s'affiche qu'au relâchement d'un appui resté seul, et la surveillance des corrections précédente n'est close qu'une fois l'écoute montrée. En saisie sécurisée (champ mot de passe, Terminal en « Secure Keyboard Entry »), le tap ne voit plus les autres touches : une touche de droite y est ignorée, Fn reste utilisable. En mains libres, un appui sur la touche ne termine la dictée qu'à son relâchement, et seulement s'il est resté seul (⌘V à droite en pleine dictée ne coupe pas l'écoute). Limite : une app qui réagit au double appui d'un modificateur (Alfred, Raycast, JetBrains, la Dictée de macOS réglée sur « deux appuis sur ⌘ ») le verra aussi ; l'accueil et les Réglages préviennent quand la Dictée de macOS est activée. Les claviers intégrés des MacBook n'ont pas de ⌃ à droite.

Le démon chauffe les moteurs au démarrage avant d'annoncer qu'il est prêt ; cela compile notamment les graphes MLX et prépare le préfixe fixe du prompt Qwen. Après plus de 30 s sans dictée, il réveille aussi Parakeet et brièvement Qwen au début de l'écoute, pendant que l'audio arrive ; aucun timer ne lance d'inférence lorsque l'app reste inutilisée. Le cache de buffers MLX est plafonné à 2 Gio et vidé à la finalisation de chaque dictée ; le démon demande aussi à macOS de garder les poids résidents lorsque la limite mémoire le permet. Ce sont des réglages de gestion mémoire, pas des mesures de consommation réelle. Les seuils d'éligibilité actuels sont 8 Go pour le mode léger et 16 Go pour le mode complet ; ils ne constituent pas une mesure de pic mémoire sur chaque modèle de Mac. Les latences mesurées avant le passage à Parakeet concernaient Voxtral et Qwen2.5 : elles sont historiques et ne décrivent pas la chaîne actuelle. Voir [les mesures et leur protocole](PERFORMANCE.md).

## Construire et installer

Prérequis : Xcode 16 ou plus récent (Swift 5.10+), macOS 14 ou plus récent sur Apple Silicon. `uv` n'est utile que pour les tests du démon et `release.sh` : l'app embarque le sien.

```bash
macos/scripts/build_app.sh --install
```

Le script compile en release, télécharge uv 0.12.24 (empreinte SHA-256 vérifiée, licences au même tag) et le copie dans `Contents/Helpers/uv`, copie le démon dans `Contents/Resources/daemon`, les textes dans `Contents/Resources/{en,fr}.lproj` et Sparkle dans `Contents/Frameworks`, signe avec ton identité **Apple Development** (sinon en ad hoc), avec le runtime renforcé et le droit micro, puis installe l'app dans `~/Applications/VoxFlow.app`. Avec une signature stable, macOS garde les autorisations d'une compilation à l'autre.

Tests :

```bash
swift test --package-path macos
```

Au premier lancement, VoxFlow reprend le lexique appris et le jeton de l'ancien dossier `~/.wispr_clone`. Il n'y touche pas : tu peux le supprimer une fois `~/.voxflow` vérifié.

```bash
cd daemon && uv run --frozen python -m unittest test_inference_daemon test_model_store
```

Localisation : les textes sont dans `macos/Resources/{en,fr}.lproj/Localizable.strings`, lus par `L10n.tr` dans `Bundle.main`. Ne pas déclarer de `resources:` dans `Package.swift` : SwiftPM créerait un bundle à part que `build_app.sh` n'embarque pas, et l'app afficherait les clés brutes. Le test `LocalizationTests` vérifie que les deux langues ont les mêmes clés et les mêmes marqueurs `%@`/`%ld`. Un Mac ni en français ni en anglais affiche l'anglais.

Captures de contrôle sans écran ni autorisations :

```bash
macos/build/VoxFlow.app/Contents/MacOS/VoxFlow --snapshots /tmp/voxflow-captures -AppleLanguages "(en)"
```

## Permissions macOS

| Permission | Pourquoi | Où |
|---|---|---|
| **Accessibilité** | `CGEventTap` actif (touche de dictée, frappes), lecture des champs (`AXUIElement`), Cmd+V synthétique | Réglages > Confidentialité et sécurité > Accessibilité > VoxFlow |
| **Micro** | Capture `AVAudioEngine` pendant la dictée (`NSMicrophoneUsageDescription`) | Demandée par l'accueil |

Un `CGEventTap` créé après un accord donné pendant que l'app tourne ne reçoit aucune touche (constaté sur macOS 27, coche verte comprise). Tant que l'accessibilité manque, l'app sonde donc `AXIsProcessTrusted` chaque seconde ; dès l'accord, elle se relance seule (un `/bin/sh` attend la fin du processus puis lance `/usr/bin/open` avec `--args --relaunched-for-accessibility`, les variables `VOXFLOW_*` et `HF_*` et les arguments de lancement transmis) et l'accueil reprend à la page où il était (`onboardingPage`). `open` est tenté cinq fois ; un échec final est noté dans `app.log`. Hors d'un bundle `.app`, VoxFlow ne quitte pas et demande une relance à la main. Si le tap ne démarre pas malgré l'accord, il est retenté chaque seconde.

Avec Fn, il faut aussi régler la touche Globe : Réglages > Clavier > « Appuyer sur la touche 🌐 pour » → **Ne rien faire**. Sinon le sélecteur d'emoji, la dictée Apple ou le changement de langue se déclenchent en même temps. L'accueil et le menu vérifient ce réglage ; il ne concerne pas les touches de droite.

## Premier lancement

Au premier lancement, l'accueil (5 pages : bienvenue, moteurs, autorisations, touche, essai) s'ouvre et la préparation démarre aussitôt, en arrière-plan :

1. **Python** : le uv embarqué lance `uv sync --frozen --python 3.12` dans un environnement hermétique (`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `UV_NO_CONFIG=1`, `UV_PYTHON_PREFERENCE=only-managed`, proxys et `HF_*` transmis). Il télécharge Python 3.12 (python-build-standalone) et les paquets de `uv.lock`, environ 150 Mo. L'avancement est lu dans les lignes « Downloading x (n MiB) » / « Downloaded x ». Un marqueur `~/.voxflow/venv/.voxflow-ready` (empreinte de `uv.lock`) évite de refaire l'étape ; une nouvelle version de `uv.lock` la relance.
2. **Démon** : lancé avec `~/.voxflow/venv/bin/python` (plus de `uv run`), `--parent-pid` pour s'arrêter si l'app disparaît, et `--no-llm` en mode léger.
3. **Modèles** : `model_store.py` télécharge les révisions figées dans `~/.voxflow/models/<dépôt>`, en HTTP Range avec fichiers `.part` : une coupure reprend où elle en était, chaque fichier LFS est vérifié en SHA-256, et l'espace disque est contrôlé avant le téléchargement (avec 1 Gio de marge). Parakeet TDT 0.6B v3 utilise la révision `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15` (2 508 940 517 octets, environ 2,51 GB décimaux) ; Qwen3.5 4B utilise `32f3e8ecf65426fc3306969496342d504bfa13f3` (3 061 129 077 octets, environ 3,06 GB). Le mode complet télécharge donc 5 570 069 594 octets au total (environ 5,57 GB, ou 5,19 Gio) ; le mode léger ne télécharge que Parakeet. Les installations 0.1.0 peuvent encore avoir des entrées Voxtral/Qwen2.5 dans le cache Hugging Face, mais celles-ci ne sont pas les modèles par défaut actuels. Les modèles du magasin sont ensuite chargés depuis le disque avec `HF_HUB_OFFLINE=1` : plus aucun appel réseau n'est fait pour les charger.

Tant que le mode n'est pas validé sur la page Moteurs, le démon tourne en léger (`runningMode`) : Parakeet, commun aux deux modes, se télécharge pendant que l'utilisateur lit l'accueil. « Suivant » sur cette page valide le choix (`engineModeConfirmed`), comme un clic sur un mode dans les Réglages ; en complet, le démon est relancé et Qwen3.5 s'ajoute. Les installations dont l'accueil est déjà terminé gardent leur mode tel quel, de même qu'une 0.1.1 mise à jour avant la fin de son accueil (dossier `venv` présent au premier lancement de la 0.1.2). Les anciennes mesures d'installation de 90 s et de 7,44 Go concernaient l'ancienne paire de modèles ; elles ne prédisent pas le temps de téléchargement actuel, qui dépend du réseau. Les tailles figées actuelles sont données ci-dessus et les mesures historiques sont distinguées dans [PERFORMANCE.md](PERFORMANCE.md).

`GET /health` (sans jeton, lecture seule ; refusé si l'en-tête Host n'est pas `127.0.0.1`, `localhost` ou `[::1]` avec le port, ou si la requête porte un Origin) renvoie toujours `status` (`loading`, `ready`, `error`) et `error`, plus `pid`, `mode` (`full`, `light`), `version` (celle de l'app qui l'a lancé, `VOXFLOW_APP_VERSION`, null s'il a été lancé à la main), `phase` (`checking`, `downloading`, `loading`, `warmup`, `ready`, `error`), `bytes_done`/`bytes_total` (tous modèles du mode), `speed_bps`, `eta_s`, `models[]`, `retry` pendant une attente avant nouvel essai, et en cas d'échec `error_code` (`network`, `tls`, `disk_full`, `low_memory`, `unsupported_cpu`, `hub_unavailable`, `hub_refused`, `integrity`, `unknown`), `retryable`, `disk_needed_bytes` et `disk_free_bytes` (null tant qu'ils n'ont pas été mesurés). L'app traduit le code en texte et en boutons (Réessayer, Passer en mode léger, Ouvrir Stockage, Copier le journal) et ajoute `port_busy` et `crashed`.

Reprises : le démon retente seul `network`, `hub_unavailable` et `integrity` (attente croissante) ; `disk_full` et `unknown` échouent tout de suite. Une fois le démon en échec réseau, l'app le relance au bout de 1, 2 puis 5 minutes. Un démon prêt qui plante est relancé automatiquement au plus une fois par tranche de 10 minutes. L'espace libre retenu est le plus grand entre statfs et `volumeAvailableCapacityForImportantUsage` (purgeable APFS compris), transmis par l'app dans `VOXFLOW_DISK_AVAILABLE`. Après l'accueil, passer du mode léger prêt au complet demande confirmation (Qwen à télécharger, dictée indisponible pendant ce temps). Changer de mode pendant l'installation de Python ne l'interrompt pas.

Modes : **complet** (Parakeet + Qwen3.5, environ 5,57 GB de modèles à télécharger) ou **léger** (Parakeet seul, environ 2,51 GB). En léger, les hésitations simples et les corrections sûres du lexique sont traitées localement, mais les répétitions, reprises et ambiguïtés ne bénéficient pas du nettoyage Qwen. L'accueil conseille le léger sous 16 Go de mémoire ; le démon refuse le complet sous 16 Go et tout mode sous 8 Go. Ce sont des seuils logiciels de capacité, pas des pics mesurés de consommation mémoire ; les anciennes mesures mémoire de Voxtral ne s'appliquent pas à la paire actuelle.

Tout vit dans `~/.voxflow` : lexique, jeton, journaux (`app.log`, `daemon.log` ; ce dernier ne contient jamais le texte dicté, sauf avec `VOXFLOW_DEBUG=1`, et l'app le réduit à son dernier Mo au lancement en masquant le texte qu'y écrivait la 0.1.0), Python (`python/`), cache uv (`uv-cache/`), environnement (`venv/`), modèles (`models/`). Pour les essais, `VOXFLOW_DATA_DIR`, `VOXFLOW_PORT` et `VOXFLOW_DEFAULTS_SUITE` isolent une installation complète sans toucher à la vraie. Un essai de première installation demande `VOXFLOW_DATA_DIR` et `VOXFLOW_DEFAULTS_SUITE` ensemble : la reprise des 0.1.1 lit le dossier `venv` d'un côté et note son passage dans les préférences de l'autre.

Pour lancer le démon à la main (l'app reprend un démon déjà à l'écoute s'il tourne dans le bon mode et vient de la même version ou a été lancé à la main ; sinon, s'il s'agit d'un démon VoxFlow, elle l'arrête pour libérer le port) :

```bash
cd daemon && uv run --frozen python inference_daemon.py
```

Autres options : `--no-llm` (transcription sans Qwen), `--asr-model` (Parakeet par défaut ; Whisper et Voxtral restent compatibles) et `--llm-model` (ou les variables `VOXFLOW_ASR_MODEL` et `VOXFLOW_LLM_MODEL`), `--mock` (moteurs factices). `--delay-ms` reste disponible pour les moteurs ASR qui utilisent un délai de streaming, notamment Voxtral ; il ne règle pas le découpage de Parakeet.

## Distribution (gratuite, signée, notarisée, mise à jour par Sparkle)

Une version se prépare en une commande, puis se publie séparément :

```bash
macos/scripts/release.sh 0.2.0 notes.txt
```

```bash
macos/scripts/publish_release.sh 0.2.0
```

`release.sh` vérifie les prérequis, régénère les licences depuis `uv.lock` (plus uv, Python et Sparkle), signe avec **Developer ID Application** (runtime renforcé, horodatage), fait notariser l'app puis le DMG par Apple, agrafe les tickets, contrôle Gatekeeper (`spctl`), signe le DMG en EdDSA et ajoute la version à `macos/release/appcast.xml`, lui-même signé. Il ne publie rien. `publish_release.sh` crée la release GitHub avec le DMG et l'appcast.

Les apps installées vérifient le flux une fois par jour. Elles refusent un flux non signé (`SURequireSignedFeed`) et vérifient la signature EdDSA du DMG avant de l'ouvrir (`SUVerifyUpdateBeforeExtraction`). Le numéro de version sert aussi de `CFBundleVersion` : il doit toujours augmenter.

Prérequis, à faire une seule fois :
- certificat **Developer ID Application** de l'équipe KX5QF45WFE dans le trousseau ;
- profil de notarisation `VoxFlowNotary` (`xcrun notarytool store-credentials`) ;
- clé EdDSA Sparkle dans le trousseau, compte `voxflow`, créée le 23/10/2026. Sa clé publique est dans l'Info.plist. **La perdre empêche toute mise à jour des apps déjà installées** : en garder une copie dans un gestionnaire de mots de passe (`generate_keys --account voxflow -x fichier`) ;
- `macos/release.env`, copié depuis `release.env.example`. L'adresse du flux est gravée dans l'app : ne plus la changer après la première diffusion.

Tant que `release.env` n'existe pas, les compilations locales n'ont pas de flux et le menu « Rechercher des mises à jour… » est masqué.

## Crédits

Transcription par **Parakeet TDT 0.6B v3** (NVIDIA, CC BY 4.0, conversion MLX de mlx-community), mise en forme facultative par **Qwen3.5 4B** (équipe Qwen, Alibaba Cloud, Apache 2.0). **Whisper large-v3-turbo** (MIT) et **Voxtral Mini 4B Realtime** (Mistral AI, Apache 2.0) restent des moteurs ASR compatibles. Les modèles tournent par **MLX** (Apple, MIT), avec mlx-audio et mlx-lm. Mises à jour par **Sparkle** (MIT). Python et les paquets installés par **uv** (Astral, MIT ou Apache 2.0, embarqué dans l'app). Le détail des licences, paquets Python compris, est dans `macos/Resources/THIRD_PARTY_NOTICES.txt` et dans le menu « Licences tierces… ». VoxFlow est sous licence MIT.

## Sécurité et vie privée

- Le démon n'écoute que sur 127.0.0.1. Chaque WebSocket exige le jeton de `~/.voxflow/token` (mode 600), et toute requête avec un en-tête `Origin` est refusée : aucune page web ne peut le piloter.
- Les frappes ne sont observées que pendant les 25 s qui suivent un collage, et uniquement en mémoire. Les champs mot de passe (`AXSecureTextField`) ne sont jamais lus.
- Le contenu collé est marqué `org.nspasteboard.TransientType`, pour que les gestionnaires de presse-papier l'ignorent.

## Limites connues

- Le premier lancement télécharge environ 150 Mo (Python) puis les modèles épinglés : 2 508 940 517 octets en mode léger ou 5 570 069 594 octets en mode complet. Il faut une connexion à ce moment-là ; ensuite VoxFlow marche hors ligne. Les modèles ne sont plus mis à jour seuls : une nouvelle révision passe par une nouvelle version de l'app.
- **Apple Silicon uniquement** (MLX), macOS 14 ou plus récent.
- **Chrome, Brave, Edge et Arc** ignorent `AXManualAccessibility`. VoxFlow active alors `AXEnhancedUserInterface`, qui peut ralentir les animations de fenêtres de ces navigateurs.
- **VS Code et Cursor (Monaco)** n'exposent parfois que les lignes visibles. Si le texte collé est introuvable dans la valeur AX, la surveillance passe au buffer clavier.
- **Buffer clavier** : un clic, Cmd+Z, Tab, ou les flèches haut et bas arrêtent le suivi. Les corrections faites avant restent apprises.
- Parakeet ne reçoit pas de prompt lexical : un nom propre appris ne peut donc pas corriger directement sa reconnaissance. En mode complet, le lexique peut corriger certaines variantes lors du nettoyage Qwen ; en mode léger, seules les correspondances déterministes sûres sont appliquées. Le démon accepte aussi Whisper ou Voxtral via `--asr-model`, et un autre modèle de nettoyage via `--llm-model`.
