# VoxFlow — documentation technique (français)

Maintiens **Fn** pour dicter, ou **double-tape Fn** pour dicter mains libres (un appui sur Fn termine). Le texte est transcrit par **Voxtral Mini 4B Realtime**, nettoyé par **Qwen2.5-Coder-7B-Instruct 4 bits**, puis collé au curseur. VoxFlow observe ensuite tes corrections pendant 25 s et apprend ton vocabulaire (« Allo » → « Allauch », « facil a beau » → « FacilAbo »).

Tout tourne en local : aucun audio ni texte ne quitte le Mac.

## Arborescence

```
VoxFlow/
├── README.md
├── LICENSE                              MIT
├── daemon/                              Démon Python MLX (WebSocket 127.0.0.1:8765)
│   ├── inference_daemon.py              Voxtral (streaming) + Qwen (nettoyage) + dictionnaire SQLite
│   ├── test_inference_daemon.py         Tests sans modèles (--mock)
│   ├── pyproject.toml                   mlx-audio[stt] ≥ 0.6.1, mlx-lm ≥ 0.32.2, websockets ≥ 14
│   └── uv.lock
└── macos/                               App Swift (barre de menu, LSUIElement)
    ├── Package.swift                    Dépendance : Sparkle 2.10 (mises à jour)
    ├── release.env.example              Adresses du flux et du dépôt de diffusion (à copier en release.env)
    ├── Resources/Info.plist             Version, copyright, clé publique Sparkle
    ├── Resources/VoxFlow.entitlements   Droit micro (runtime renforcé)
    ├── Resources/VoxFlow.icon           Icône Icon Composer (fond noir, vagues, point rouge ; compilée par actool)
    ├── Resources/THIRD_PARTY_NOTICES.txt  Crédits et licences (généré par make_notices.py)
    ├── scripts/build_app.sh             Build release + démon + Sparkle, signature runtime renforcé
    ├── scripts/release.sh               Developer ID, notarisation, DMG, appcast signé (ne publie rien)
    ├── scripts/publish_release.sh       Mise en ligne sur GitHub Releases
    ├── scripts/make_notices.py          Génère les licences tierces
    ├── scripts/update_appcast.py        Ajoute une version à l'appcast
    ├── Sources/VoxFlow/
    │   ├── main.swift
    │   ├── AppController.swift          Chef d'orchestre + menu (dont mises à jour Sparkle)
    │   ├── AboutPanel.swift             Fenêtre « À propos » et crédits (VoxFlow --about-demo)
    │   ├── AppLog.swift                 Journal ~/.voxflow/app.log (appuis Fn, durées)
    │   └── HUDDemo.swift                VoxFlow --hud-demo [ecoute|verrouille|traitement|appris]
    ├── Sources/VoxFlowCore/
    │   ├── FnKeyStateMachine.swift      Push-to-talk / double-tap lock (CGEventTap, flagsChanged)
    │   ├── GlobalEventTap.swift         Tap unique : Fn, frappes de surveillance, clics
    │   ├── AccessibilityMonitor.swift   Collage, AXManualAccessibility, surveillance AX + buffer clavier
    │   ├── DiffLearner.swift            Alignement mot à mot, filtres, SQLite
    │   ├── AudioCapture.swift           AVAudioEngine → PCM Float32 16 kHz mono
    │   ├── InferenceClient.swift        Client WebSocket + lancement du démon (uv)
    │   ├── HUDPanel.swift               Pilule « Dynamic Island » à vagues (NSPanel non activable, .floating)
    │   ├── SystemAudioMuter.swift       Coupe le son du Mac pendant l'écoute
    │   └── VoxFlowPaths.swift           Dossier ~/.voxflow et reprise de l'ancien ~/.wispr_clone
    └── Tests/VoxFlowCoreTests/          27 tests XCTest
```

## Chaîne de traitement

1. **Appui sur Fn** : l'enregistrement démarre aussitôt. VoxFlow pose `AXManualAccessibility` sur l'app au premier plan, pour que VS Code, Cursor, Slack ou Chrome aient le temps d'exposer leurs champs. L'audio part au démon par blocs, pendant que tu parles.
2. **Démon** : Voxtral transcrit en streaming (`create_streaming_session`, `temperature=0.0`, `transcription_delay_ms=480`). À l'arrêt, il ne reste que la fin de l'audio à décoder.
3. **Nettoyage** : si Voxtral rend déjà un texte propre (ni hésitation, ni reprise, ni mot du dictionnaire dépendant du contexte), Qwen est sauté et seuls le dictionnaire sans ambiguïté et la typographie française s'appliquent. Sinon, sélection des règles du lexique (correspondance floue et phonétique sur la transcription brute, plus le Top 100 des plus fréquentes), bloc `<dictionnaire_utilisateur>`, prompt anti-réponse et sortie imposée entre `<texte_nettoye>`. Une sortie sans balises, ou de longueur anormale, est rejetée au profit d'un nettoyage de secours.
4. **Collage** : sauvegarde du presse-papier, puis Cmd+V (touche « v » de ta disposition clavier, AZERTY compris), puis restauration après 150 ms.
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
- **Toasts** : « Appris : … » et erreurs.

Pour le geste, un tap dure moins de 300 ms et le second tap doit arriver dans les 400 ms. Ces seuils ont été élargis par rapport aux 250 ms du cahier des charges, après l'essai réel.

Durée mesurée sur un M4 Pro 24 Go, du relâchement de Fn au texte collé : 0,9 à 1,2 s quand Qwen est sauté, 2,3 à 2,8 s sinon. Environ 0,9 s ne peut pas être réduit : c'est la fin de la fenêtre de 480 ms de Voxtral. Après chaque transcription, le cache MLX est plafonné à 2 Go puis vidé ; sans cela, Qwen tombait en swap et la dictée prenait 30 s.

## Construire et installer

Prérequis : Xcode 16 ou plus récent (Swift 5.10+), `uv` (`brew install uv`), macOS 14 ou plus récent sur Apple Silicon.

```bash
macos/scripts/build_app.sh --install
```

Le script compile en release, copie le démon dans `VoxFlow.app/Contents/Resources/daemon` et Sparkle dans `Contents/Frameworks`, signe avec ton identité **Apple Development** (sinon en ad hoc), avec le runtime renforcé et le droit micro, puis installe l'app dans `~/Applications/VoxFlow.app`. Avec une signature stable, macOS garde les autorisations d'une compilation à l'autre.

Tests :

```bash
swift test --package-path macos
```

Au premier lancement, VoxFlow reprend le lexique appris et le jeton de l'ancien dossier `~/.wispr_clone`. Il n'y touche pas : tu peux le supprimer une fois `~/.voxflow` vérifié.

```bash
cd daemon && uv run --frozen python -m unittest test_inference_daemon
```

## Permissions macOS

| Permission | Pourquoi | Où |
|---|---|---|
| **Accessibilité** | `CGEventTap` actif (Fn, frappes), lecture des champs (`AXUIElement`), Cmd+V synthétique | Réglages > Confidentialité et sécurité > Accessibilité > VoxFlow |
| **Micro** | Capture `AVAudioEngine` pendant la dictée (`NSMicrophoneUsageDescription`) | Demandée au premier lancement |

Il faut aussi régler la touche Globe : Réglages > Clavier > « Appuyer sur la touche 🌐 pour » → **Ne rien faire**. Sinon le sélecteur d'emoji, la dictée Apple ou le changement de langue se déclenchent en même temps. Le menu de VoxFlow t'avertit si ce réglage n'est pas fait.

## Premier lancement

Au démarrage, l'app lance le démon : `uv run --frozen --python 3.12`, avec l'environnement Python dans `~/.voxflow/venv`. Le premier lancement installe les paquets et **télécharge environ 7,5 Go de modèles** (Voxtral 4 bits : 3,15 Go ; Qwen2.5-Coder-7B 4 bits : 4,3 Go) dans le cache Hugging Face. Tu peux suivre l'avancement dans `~/.voxflow/daemon.log`. Le menu affiche ensuite « démon : prêt ».

Une fois chargés, les deux modèles occupent environ 8 Go de mémoire unifiée, ce qui tient sur un M4 Pro 24 Go.

Pour lancer le démon à la main :

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

`release.sh` vérifie les prérequis, régénère les licences depuis `uv.lock`, signe avec **Developer ID Application** (runtime renforcé, horodatage), fait notariser l'app puis le DMG par Apple, agrafe les tickets, contrôle Gatekeeper (`spctl`), signe le DMG en EdDSA et ajoute la version à `macos/release/appcast.xml`, lui-même signé. Il ne publie rien. `publish_release.sh` crée la release GitHub avec le DMG et l'appcast.

Les apps installées vérifient le flux une fois par jour. Elles refusent un flux non signé (`SURequireSignedFeed`) et vérifient la signature EdDSA du DMG avant de l'ouvrir (`SUVerifyUpdateBeforeExtraction`). Le numéro de version sert aussi de `CFBundleVersion` : il doit toujours augmenter.

Prérequis, à faire une seule fois :
- certificat **Developer ID Application** de l'équipe KX5QF45WFE dans le trousseau ;
- profil de notarisation `VoxFlowNotary` (`xcrun notarytool store-credentials`) ;
- clé EdDSA Sparkle dans le trousseau, compte `voxflow`, créée le 23/10/2026. Sa clé publique est dans l'Info.plist. **La perdre empêche toute mise à jour des apps déjà installées** : en garder une copie dans un gestionnaire de mots de passe (`generate_keys --account voxflow -x fichier`) ;
- `macos/release.env`, copié depuis `release.env.example`. L'adresse du flux est gravée dans l'app : ne plus la changer après la première diffusion.

Tant que `release.env` n'existe pas, les compilations locales n'ont pas de flux et le menu « Rechercher des mises à jour… » est masqué.

## Crédits

Transcription par **Voxtral Mini 4B Realtime** (Mistral AI), mise en forme par **Qwen2.5-Coder-7B-Instruct** (équipe Qwen, Alibaba Cloud), tous deux sous licence Apache 2.0 et exécutés par **MLX** (Apple, MIT), avec mlx-audio et mlx-lm. Mises à jour par **Sparkle** (MIT). Le détail des licences, paquets Python compris, est dans `macos/Resources/THIRD_PARTY_NOTICES.txt` et dans le menu « Licences tierces… ». VoxFlow est sous licence MIT.

## Sécurité et vie privée

- Le démon n'écoute que sur 127.0.0.1. Chaque WebSocket exige le jeton de `~/.voxflow/token` (mode 600), et toute requête avec un en-tête `Origin` est refusée : aucune page web ne peut le piloter.
- Les frappes ne sont observées que pendant les 25 s qui suivent un collage, et uniquement en mémoire. Les champs mot de passe (`AXSecureTextField`) ne sont jamais lus.
- Le contenu collé est marqué `org.nspasteboard.TransientType`, pour que les gestionnaires de presse-papier l'ignorent.

## Limites connues

- **uv est obligatoire** (`brew install uv`) et le premier lancement télécharge environ 7,5 Go. L'app n'embarque ni Python ni les modèles.
- **Apple Silicon uniquement** (MLX), macOS 14 ou plus récent.
- **Chrome, Brave, Edge et Arc** ignorent `AXManualAccessibility`. VoxFlow active alors `AXEnhancedUserInterface`, qui peut ralentir les animations de fenêtres de ces navigateurs.
- **VS Code et Cursor (Monaco)** n'exposent parfois que les lignes visibles. Si le texte collé est introuvable dans la valeur AX, la surveillance passe au buffer clavier.
- **Buffer clavier** : un clic, Cmd+Z, Tab, ou les flèches haut et bas arrêtent le suivi. Les corrections faites avant restent apprises.
- **Qwen2.5-Coder** est un modèle orienté code. Il suit bien le format imposé, mais un modèle généraliste ponctuerait sans doute mieux le français. Le démon accepte un autre modèle via `--llm-model` sans changer de code.
