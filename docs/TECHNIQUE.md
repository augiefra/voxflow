# VoxFlow — documentation technique (français)

Maintiens **Fn** (ou la touche choisie : ⌘, ⌥ ou ⌃ de droite) pour dicter, ou **appuie deux fois** pour dicter mains libres (un appui termine). Le texte est transcrit par **Voxtral Mini 4B Realtime**, nettoyé par **Qwen2.5-Coder-7B-Instruct 4 bits**, puis collé au curseur. VoxFlow observe ensuite tes corrections pendant 25 s et apprend ton vocabulaire (« Allo » → « Allauch », « facil a beau » → « FacilAbo »).

Tout tourne en local : aucun audio ni texte ne quitte le Mac.

## Arborescence

```
VoxFlow/
├── README.md
├── LICENSE                              MIT
├── daemon/                              Démon Python MLX (WebSocket 127.0.0.1:8765)
│   ├── inference_daemon.py              Voxtral (streaming) + Qwen (nettoyage) + dictionnaire SQLite
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
2. **Démon** : Voxtral transcrit en streaming (`create_streaming_session`, `temperature=0.0`, `transcription_delay_ms=480`). À l'arrêt, il ne reste que la fin de l'audio à décoder.
3. **Nettoyage** : si Voxtral rend déjà un texte propre (ni hésitation, ni reprise, ni mot du dictionnaire dépendant du contexte), Qwen est sauté et seuls le dictionnaire sans ambiguïté et la typographie française s'appliquent. Sinon, sélection des règles du lexique (correspondance floue et phonétique sur la transcription brute, plus le Top 100 des plus fréquentes), bloc `<dictionnaire_utilisateur>`, prompt anti-réponse et sortie imposée entre `<texte_nettoye>`. Une sortie sans balises, ou de longueur anormale, est rejetée au profit d'un nettoyage de secours.
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

Durée mesurée sur un M4 Pro 24 Go, du relâchement de Fn au texte collé : 0,9 à 1,2 s quand Qwen est sauté, 2,3 à 2,8 s sinon. Environ 0,9 s ne peut pas être réduit : c'est la fin de la fenêtre de 480 ms de Voxtral. Après chaque transcription, le cache MLX est plafonné à 2 Go puis vidé ; sans cela, Qwen tombait en swap et la dictée prenait 30 s.

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
3. **Modèles** : `model_store.py` télécharge les fichiers des révisions figées (Voxtral `fdebf7b2`, 3,15 Go ; Qwen `019cc73c`, 4,30 Go) dans `~/.voxflow/models/<dépôt>`, en HTTP Range avec fichiers `.part` : une coupure reprend où elle en était, chaque fichier LFS est vérifié en SHA-256, l'espace disque est contrôlé avant (avec 1 Gio de marge). Les installations 0.1.0 réutilisent leur cache Hugging Face tel quel. Les modèles sont ensuite chargés par chemin local, avec `HF_HUB_OFFLINE=1` : plus aucun appel réseau.

Tant que le mode n'est pas validé sur la page Moteurs, le démon tourne en léger (`runningMode`) : seul Voxtral, commun aux deux modes, se télécharge pendant que l'utilisateur lit l'accueil. « Suivant » sur cette page valide le choix (`engineModeConfirmed`), comme un clic sur un mode dans les Réglages ; en complet, le démon est relancé et Qwen s'ajoute. Les installations dont l'accueil est déjà terminé gardent leur mode tel quel, de même qu'une 0.1.1 mise à jour avant la fin de son accueil (dossier `venv` présent au premier lancement de la 0.1.2). Essai du 24/10/2026 sur un dossier vide : avant validation, Voxtral seul sur le disque (2,9 Gio) ; après validation du complet, Qwen seul s'ajoute (6,9 Gio au total).

Mesure du 24/10/2026 sur ce Mac (M4 Pro 24 Go, fibre), dossier vide : prêt en 90 s (Python 4 s, modèles 7,44 Go à 85-138 Mo/s, chargement 10 s). Relance sans réseau : 10 s en complet, 4 s en léger.

`GET /health` (sans jeton, lecture seule ; refusé si l'en-tête Host n'est pas `127.0.0.1`, `localhost` ou `[::1]` avec le port, ou si la requête porte un Origin) renvoie toujours `status` (`loading`, `ready`, `error`) et `error`, plus `pid`, `mode` (`full`, `light`), `version` (celle de l'app qui l'a lancé, `VOXFLOW_APP_VERSION`, null s'il a été lancé à la main), `phase` (`checking`, `downloading`, `loading`, `warmup`, `ready`, `error`), `bytes_done`/`bytes_total` (tous modèles du mode), `speed_bps`, `eta_s`, `models[]`, `retry` pendant une attente avant nouvel essai, et en cas d'échec `error_code` (`network`, `tls`, `disk_full`, `low_memory`, `unsupported_cpu`, `hub_unavailable`, `hub_refused`, `integrity`, `unknown`), `retryable`, `disk_needed_bytes` et `disk_free_bytes` (null tant qu'ils n'ont pas été mesurés). L'app traduit le code en texte et en boutons (Réessayer, Passer en mode léger, Ouvrir Stockage, Copier le journal) et ajoute `port_busy` et `crashed`.

Reprises : le démon retente seul `network`, `hub_unavailable` et `integrity` (attente croissante) ; `disk_full` et `unknown` échouent tout de suite. Une fois le démon en échec réseau, l'app le relance au bout de 1, 2 puis 5 minutes. Un démon prêt qui plante est relancé automatiquement au plus une fois par tranche de 10 minutes. L'espace libre retenu est le plus grand entre statfs et `volumeAvailableCapacityForImportantUsage` (purgeable APFS compris), transmis par l'app dans `VOXFLOW_DISK_AVAILABLE`. Après l'accueil, passer du mode léger prêt au complet demande confirmation (Qwen à télécharger, dictée indisponible pendant ce temps). Changer de mode pendant l'installation de Python ne l'interrompt pas.

Modes : **complet** (Voxtral + Qwen, pic mesuré 8,9 Gio de mémoire) ou **léger** (Voxtral seul, pic 4,8 Gio, 3,15 Go à télécharger). Le léger retire les hésitations, met la majuscule et le point final et applique les corrections sûres du lexique, mais ne corrige ni les répétitions ni les reprises. L'accueil conseille le léger sous 16 Go de mémoire ; le démon refuse le complet sous 16 Go et tout mode sous 8 Go (seuils déduits des mesures sur 24 Go, non vérifiés sur de plus petits Mac).

Tout vit dans `~/.voxflow` : lexique, jeton, journaux (`app.log`, `daemon.log` ; ce dernier ne contient jamais le texte dicté, sauf avec `VOXFLOW_DEBUG=1`, et l'app le réduit à son dernier Mo au lancement en masquant le texte qu'y écrivait la 0.1.0), Python (`python/`), cache uv (`uv-cache/`), environnement (`venv/`), modèles (`models/`). Pour les essais, `VOXFLOW_DATA_DIR`, `VOXFLOW_PORT` et `VOXFLOW_DEFAULTS_SUITE` isolent une installation complète sans toucher à la vraie. Un essai de première installation demande `VOXFLOW_DATA_DIR` et `VOXFLOW_DEFAULTS_SUITE` ensemble : la reprise des 0.1.1 lit le dossier `venv` d'un côté et note son passage dans les préférences de l'autre.

Pour lancer le démon à la main (l'app reprend un démon déjà à l'écoute s'il tourne dans le bon mode et vient de la même version ou a été lancé à la main ; sinon, s'il s'agit d'un démon VoxFlow, elle l'arrête pour libérer le port) :

```bash
cd daemon && uv run --frozen python inference_daemon.py --delay-ms 480
```

Autres options : `--no-llm` (transcription seule), `--asr-model` et `--llm-model` (ou les variables `VOXFLOW_ASR_MODEL` et `VOXFLOW_LLM_MODEL`), `--mock` (moteurs factices pour les tests).

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

Transcription par **Voxtral Mini 4B Realtime** (Mistral AI), mise en forme par **Qwen2.5-Coder-7B-Instruct** (équipe Qwen, Alibaba Cloud), tous deux sous licence Apache 2.0 et exécutés par **MLX** (Apple, MIT), avec mlx-audio et mlx-lm. Mises à jour par **Sparkle** (MIT). Python et les paquets installés par **uv** (Astral, MIT ou Apache 2.0, embarqué dans l'app). Le détail des licences, paquets Python compris, est dans `macos/Resources/THIRD_PARTY_NOTICES.txt` et dans le menu « Licences tierces… ». VoxFlow est sous licence MIT.

## Sécurité et vie privée

- Le démon n'écoute que sur 127.0.0.1. Chaque WebSocket exige le jeton de `~/.voxflow/token` (mode 600), et toute requête avec un en-tête `Origin` est refusée : aucune page web ne peut le piloter.
- Les frappes ne sont observées que pendant les 25 s qui suivent un collage, et uniquement en mémoire. Les champs mot de passe (`AXSecureTextField`) ne sont jamais lus.
- Le contenu collé est marqué `org.nspasteboard.TransientType`, pour que les gestionnaires de presse-papier l'ignorent.

## Limites connues

- Le premier lancement télécharge environ 150 Mo (Python) puis 7,44 Go de modèles (3,15 Go en mode léger) : il faut une connexion à ce moment-là, ensuite VoxFlow marche hors ligne. Les modèles ne sont plus mis à jour seuls : une nouvelle révision passe par une nouvelle version de l'app.
- **Apple Silicon uniquement** (MLX), macOS 14 ou plus récent.
- **Chrome, Brave, Edge et Arc** ignorent `AXManualAccessibility`. VoxFlow active alors `AXEnhancedUserInterface`, qui peut ralentir les animations de fenêtres de ces navigateurs.
- **VS Code et Cursor (Monaco)** n'exposent parfois que les lignes visibles. Si le texte collé est introuvable dans la valeur AX, la surveillance passe au buffer clavier.
- **Buffer clavier** : un clic, Cmd+Z, Tab, ou les flèches haut et bas arrêtent le suivi. Les corrections faites avant restent apprises.
- **Qwen2.5-Coder** est un modèle orienté code. Il suit bien le format imposé, mais un modèle généraliste ponctuerait sans doute mieux le français. Le démon accepte un autre modèle via `--llm-model` sans changer de code.
