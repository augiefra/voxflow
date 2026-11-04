# Latence de VoxFlow — mesures du 3 novembre 2026

Sur le corpus local de **30 phrases françaises synthétiques**, le délai médian du
moteur après l'arrêt passe de **1 344,5 ms à 188,0 ms**. Le 95e percentile passe de
**2 000,4 ms à 486,9 ms**. Ces mesures s'arrêtent au résultat du démon, **avant le
collage** et sans mesurer l'affichage dans l'application cible.

| Mesure, 30 phrases | Référence installée 0.1.5, Whisper + Qwen | Parakeet + nettoyage sélectif |
| --- | ---: | ---: |
| Médiane après arrêt | 1 344,5 ms | 188,0 ms |
| 95e percentile, rang supérieur | 2 000,4 ms | 486,9 ms |
| Maximum de ce corpus | 2 257,0 ms | 487,2 ms |
| Dictées ayant appelé Qwen | 8 / 30 | 3 / 30 |

Les runs ont été effectués successivement sur un **M4 Pro, 24 Go**, sous macOS
26.2. La charge globale du Mac n'est pas contrôlée : les valeurs absolues peuvent
varier. Un premier pilote indépendant de 6 phrases répétées deux fois avait donné
949,3 ms de médiane avant et 213,1 ms après. Ces essais soutiennent le choix du
moteur ; ils ne constituent pas une mesure sur voix humaine ou une comparaison
avec Wispr Flow ou Granola.

## Protocole et preuves

- 30 enregistrements produits localement avec la voix française Thomas de macOS,
  débit 170 mots/minute ; 140,2 secondes d'audio au total, clips de 2,7 à 20,9 s.
- WAV PCM16, mono, 16 kHz. Les buffers sont injectés à la cadence réelle de la
  parole, puis la session est fermée comme au relâchement de la touche.
- Chargement et préchauffage des modèles avant le premier cas. Tous les calculs
  d'inférence d'un moteur passent par le même worker MLX, comme dans l'app.
- Les deux chaînes incluent leur nettoyage Qwen et la vidange du cache ; le lexique
  du comparatif est vide. L'aller-retour réseau WebSocket et le collage macOS ne
  font pas partie du chronométrage de ce harness.
- Les JSON conservent la transcription brute, le résultat nettoyé, les durées de
  chaque étape et l'empreinte du code mesuré. Il s'agit exclusivement de textes de
  test synthétiques, sans dictée personnelle.

Sources inspectables : [référence Whisper](performance/2026-11-03/whisper-before.json),
[Parakeet](performance/2026-11-03/parakeet-after.json),
[phrases de référence](performance/2026-11-03/manifest.json).

La référence est le fichier du moteur installé 0.1.5, identique au code local
avant ce chantier. Les empreintes SHA-256 exactes figurent dans les rapports.
Le comparatif de 30 phrases est réalisé à chaud. La clarification finale du prompt
sur les prénoms et le réveil après inactivité ont été vérifiés séparément ci-dessous ;
le décodeur ASR et le budget de nettoyage restent les mêmes.

## Ce qui change

**Parakeet TDT 0.6B v3** remplace Whisper comme choix par défaut. Le modèle est
épinglé à `ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15`, soit 2 508 940 517 octets de
fichiers à télécharger. Qwen3.5 4B conserve sa révision
`32f3e8ecf65426fc3306969496342d504bfa13f3`. Aucun paquet Python supplémentaire n'est
nécessaire. Whisper et Voxtral restent sélectionnables avec `--asr-model` ou
`VOXFLOW_ASR_MODEL` ; les anciens modèles ne sont pas supprimés.

Une pause franche d'au moins **400 ms**, dans un segment d'au moins **1,5 s**,
permet de décoder plus tôt. Le seuil de pause est conservateur et s'adapte au niveau
reçu. Un segment de voix faible n'est plus supprimé sur la seule base de son RMS
moyen. La limite longue de 28 s reste une sécurité ; le backlog à l'arrêt utilise
aussi une frontière calme et ne passe plus entier au modèle. Sans pause, le court
message est décodé à l'arrêt, avec le coût plus faible de Parakeet.

Les sons « euh », « heu », « hum » sont retirés localement lorsqu'ils ne sont pas
cités. Des formes porteuses de sens comme « Ben vient dîner », « ce genre de » ou
« très très important » ne déclenchent plus une génération à elles seules.

Le nettoyage Qwen dispose de **1,5 s partagée par toute la dictée**, et s'arrête
aussi dès la fermeture de la balise attendue. L'expiration ferme réellement le
générateur, synchronise le stream GPU et libère le worker avant de renvoyer le
secours. Une étape GPU déjà engagée peut dépasser légèrement l'échéance : ce
budget n'est pas une garantie stricte de temps réel. Le secours conserve les mots
ambigus et ajoute seulement le nettoyage local conservateur.

Le lexique distingue désormais une graphie déjà corrigée d'une variante seulement
repérée phonétiquement : cette dernière peut encore être confiée à Qwen. Les
termes canoniques peuvent aussi guider Whisper dans un petit prompt ; Parakeet
n'accepte pas ce prompt textuel.

## Vérification de 0.1.6 sur l'app installée, après inactivité

La version locale **0.1.6** a été construite et signée avec l'identité Developer ID
existante, installée dans `/Applications/VoxFlow.app`, puis ouverte. Son endpoint
local annonce `ready`, version `0.1.6`, mode `full`. Le fichier du moteur embarqué
est identique au code du dépôt (SHA-256 dans le rapport).

Le premier contrôle réel du daemon révélait encore environ **0,90 s après une
période d'inactivité**, contre **0,19 s** pour la phrase suivante. Le moteur
réveillait alors Parakeet et brièvement Qwen dès le début d'une dictée si la
dernière activité remonte à plus de **30 s**. Cela se fait dans le worker MLX
pendant que l'audio continue d'arriver ; aucun travail périodique n'est lancé
lorsque l'app est inutilisée. Une dictée très brève peut toujours se terminer
avant la fin de cette préparation.

Ce réveil a ensuite révélé un défaut sur les captures sans parole : voir le
correctif 0.1.7 ci-dessous. Ces mesures décrivent la version 0.1.6 publiée.

Le contrôle final utilise le vrai serveur WebSocket de l'app installée, son jeton
local et les mêmes WAV, sans déclencher le micro ou un collage dans une autre app :

| Cas | Résultat reçu après arrêt | Préparation pendant la parole |
| --- | ---: | ---: |
| Phrase courte après 35 s d'inactivité | 91,7 ms | 924,1 ms |
| Même phrase immédiatement après | 198,0 ms | 0 ms |
| Phrase avec « mardi, non pardon, mercredi » | 687,5 ms | 0 ms |
| Message avec pauses | 180,2 ms | 0 ms |

Le texte attendu et la reprise vers « mercredi » ont été vérifiés. Ces quatre cas
ne constituent pas un percentile représentatif de l'usage réel.
[Avant le correctif d'inactivité](performance/2026-11-03/installed-before-idle-fix.json),
[contrôle final installé](performance/2026-11-03/installed-final.json).

## Correctif 0.1.7 : arrêt sans parole

Le journal de l'app 0.1.6 montrait une capture de 0,59 s sans texte, suivie de
8 968 ms d'attente ASR après relâchement. Le réveil anticipé durait 9 682 ms et
retenait le worker avant la transcription, même sans texte à nettoyer.

Le réveil facultatif attend maintenant au moins une seconde d'audio non nul et
vérifie que la capture est encore ouverte, y compris au démarrage du travail
dans le worker. Il prépare uniquement Parakeet : Qwen est appelé par le nettoyage
lorsqu'un texte le justifie. Aucun seuil de volume ne rejette les échantillons.
Le silence numérique ne réinitialise pas l'horloge d'activité des modèles.

Essais via le vrai WebSocket local de l'app signée 0.1.7, sans micro ni collage :

| Cas | Résultat reçu après arrêt | Texte |
| --- | ---: | --- |
| Aucun audio reçu | 33,7 ms | Vide |
| Silence numérique de 0,6 s après 35 s d'inactivité | 22,1 ms | Vide |
| Bruit synthétique bref de 0,6 s, sans réveil préalable | 203,9 ms | Vide |
| Bruit synthétique de 3 s après 35 s d'inactivité | 95,7 ms | Faux positif ASR |
| Silence numérique de 3 s | 32,7 ms | Vide |
| Phrase synthétique courte | 192,1 ms | Phrase attendue |
| Même phrase atténuée 100 fois | 193,2 ms | Phrase attendue |
| Phrase après le silence long | 754,4 ms | Phrase attendue |

Le bruit long termine rapidement mais produit « It's a good one. » : le correctif
de latence ne constitue donc pas un détecteur de parole et n'élimine pas tous les
faux positifs du moteur. Les cas ambigus restent transcrits pour préserver la
parole faible. Ce bruit est synthétique, pas un enregistrement de pièce.

Les 60 tests Python passent, dont les captures vides, la conservation de tous les
échantillons d'une voix faible, la réception audio pendant le réveil et un arrêt
survenant avant qu'un réveil mis en file ait commencé. Le code Swift existant
masque le HUD et libère la touche occupée dès qu'un résultat vide est reçu.

Le contrôle de la version finale signée confirme 20,6 ms pour le silence bref,
161,4 ms pour le bruit bref et 181,5 ms pour la phrase atténuée 100 fois. Une
reprise (« mardi, non pardon, mercredi ») après 35 s d'inactivité est correctement
nettoyée en 823,6 ms, dont 588,2 ms pour Qwen. Ces contrôles ne représentent pas
un percentile ni une garantie sur tous les Mac. Les mesures et les empreintes
des moteurs embarqués sont dans le [rapport JSON](performance/2026-11-03/no-speech-fix.json).

## Contexte audio et ressources — version 0.1.8, 4 novembre

Parakeet détecte automatiquement la langue ; l'implémentation MLX utilisée ne
permet pas de forcer `language="fr"` sur ce chemin. Chaque morceau repartait sans
audio précédent. La version 0.1.8 conserve jusqu'à 2 s d'audio et fusionne
les tokens horodatés. Les résultats partiels sont des snapshots révisables. Un
raccord sans ancre fiable revient au décodage de la nouvelle tranche seule.

Le [comparatif ASR](performance/2026-11-04/audio-context-comparison.json) utilise
un seul modèle chargé, des trames virtuelles de 100 ms et 43 cas synthétiques :
les 30 clips initiaux, une coupure forcée, une voix faible avec pause, un silence,
puis dix fins courtes françaises. Les 33 premiers cas gardent le même WER ; cinq
fins courtes sont mieux orthographiées (« préparé », « précisé », « présenté »).
La médiane du travail ASR restant après clôture vaut 39,9 ms avant et 40,8 ms
après ; les raccords mesurés ajoutent généralement 10 à 20 ms. Ces valeurs sont
un microbenchmark sans attente temps réel, pas la latence complète de l'app.

La dernière protection sur un token traversant la coupure a été ajoutée après
ce comparatif, puis couverte par les 70 tests Python. Le [contrôle installé en
temps réel](performance/2026-11-04/installed-context.json) confirme le silence
(19,7 ms), le contexte d'une fin courte (97,3 ms), la voix atténuée avec pause
(220,6 ms), une nouvelle dictée indépendante (160,7 ms) et le nettoyage Qwen
(882,4 ms). Le cas audio exact du changement en anglais n'est pas disponible :
ces contrôles ne prouvent pas la disparition de toute confusion de langue.

Le tampon supplémentaire est borné à 128 000 octets (125 Kio), en plus des
tokens horodatés ; aucun modèle supplémentaire n'est chargé dans l'app.
Sur le M4 Pro de 24 Go, le relevé initial en mode Complet donnait une empreinte
mémoire du moteur de 5,2 Gio, avec un pic de 7,4 Gio depuis son lancement, et
33 Mio pour l'interface. Le CPU au repos était proche de zéro sur deux relevés.
L'installation gérée (app, modèles, Python et venv) occupait environ 7,8 Go sur
le disque, dont 1,6 Go de l'ancien Whisper conservé. Le swap global de 10,5 Go
concernait toutes les applications du Mac ; ce n'est pas une mesure attribuable
à VoxFlow seul. L'autonomie n'a pas été mesurée.

Après relance en 0.1.8 et les cinq contrôles installés, `vmmap` relève encore
5,2 Gio pour le moteur, avec un pic de 6,5 Gio sur cette nouvelle durée de vie.
Les fenêtres d'observation diffèrent : cela ne mesure pas une réduction du pic.

## Qualité et robustesse

Les noms propres restent la principale limite. Sans lexique, le clip de noms
devient notamment « Facile Abo » et « Eric Colonier » avec Parakeet ; Whisper
produit « Facilabo » et « Eric Colony ». Il n'y a donc pas de preuve que le nouveau
modèle reconnaît mieux tous les noms. Avec des variantes apprises dans le lexique,
un essai réel du nettoyage restitue « FacilAbo », « Eric Cologni » et « Allauch ».

Dans les exemples du corpus, l'ancienne chaîne supprimait le prénom Ben et la
répétition d'insistance « très très ». Le filtrage conservateur les préserve. Les
reprises simples, comme « mardi, non pardon, mercredi », sont nettoyées ; les
corrections complexes restent à valider avec une voix humaine. Une reprise avec
un prénom répété a conservé le prénom mais aussi une partie du faux départ.

Le WER brut des JSON n'est pas une note de qualité de dictée : il pénalise aussi
les transcriptions équivalentes de nombres (« quinze heures » / « 15h »), la
suppression d'un bégaiement et le découpage des noms. Il vaut 7,30 % en moyenne par
clip avant, 8,13 % après ; on ne conclut pas à une amélioration globale de précision
sur cette base.

Les [contrôles ciblés sur les vrais modèles](performance/2026-11-03/robustness.json)
ont aussi vérifié :

- la même phrase atténuée 100 fois conserve son texte ; silence numérique et
  deux bruits synthétiques de RMS 0,0005 et 0,003 donnent un texte vide avec Parakeet ;
- une génération longue est interrompue vers 1,52 s et le secours conserve tous
  les mots ; la dictée suivante est nettoyée en environ 0,40 s, sans génération
  abandonnée qui continuerait derrière elle ;
- le prénom Ben, même mêlé à une reprise, reste présent ; « le mot “euh” » et les
  graphies apprises sont préservés dans les cas vérifiés.

Ces bruits synthétiques ne couvrent pas tous les bruits de pièce, souffles,
microphones ou niveaux de voix. Le comportement du Whisper optionnel face au bruit
n'a pas été revérifié avec ce nouveau seuil ; son filtrage historique de crédits
hallucinés reste présent.

SpeechAnalyzer d'Apple a aussi été sondé : fr-FR est disponible sur ce Mac et deux
clips finissent environ 38 à 90 ms après l'audio. Les noms sont toutefois moins
bien reconnus dans ces deux essais ; ce moteur n'est pas intégré par défaut.
[Résultats natifs et limites](performance/2026-11-03/speech-analyzer.md),
[script de sonde](performance/2026-11-03/speech_bench.swift).

## Reproduire les mesures

Avec l'environnement Python de VoxFlow et les modèles déjà présents localement :

```sh
python daemon/benchmark_latency.py --make-fixtures /tmp/voxflow-audio
python daemon/benchmark_latency.py \
  --manifest /tmp/voxflow-audio/manifest.json \
  --asr-path "$HOME/.voxflow/models/parakeet-tdt-0.6b-v3" \
  --llm-path "$HOME/.voxflow/models/Qwen3.5-4B-MLX-4bit" \
  --realtime --output /tmp/voxflow-result.json
```

Le harness requiert un accès au service de synthèse vocale et au GPU du Mac. Il
refuse les fichiers audio vides et n'effectue pas de téléchargement implicite.
`--daemon-dir` permet de mesurer une copie de référence ; `--cases` et `--repeats`
sélectionnent des cas. `--include-text` ajoute les textes au JSON et doit être
réservé à des audios que l'on accepte de conserver dans le rapport.

## Validation de l'application

Les **56 tests Python** couvrent notamment la conservation de tous les échantillons, les
frontières calmes, la voix faible, les mots cités, le dictionnaire, l'interruption
de génération, le budget partagé et l'arrivée de l'audio pendant le réveil du
worker. La suite Swift de 68 tests a terminé sans échec, dont l'aller-retour du
client avec le démon de test isolé ; le test qui coupe réellement la sortie audio
du Mac est resté désactivé. Les 12 tests des réglages et touches ont été revérifiés
après correction de la taille totale des modèles.

L'app journalise désormais le délai jusqu'au résultat reçu et jusqu'à l'émission
de Cmd+V, sans texte dicté. L'émission de la commande ne prouve pas que l'app cible
a affiché le texte : un essai avec la voix de l'utilisateur, dans ses champs
habituels et après une période d'inactivité, reste la validation d'usage suivante.
