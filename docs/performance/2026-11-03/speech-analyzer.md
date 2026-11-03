# Résultats SpeechAnalyzer / SpeechTranscriber

Exécution locale le 3 novembre 2026. Machine Apple Silicon M4 Pro, 24 Go (information de la session). macOS 26.2, build 26B123 ; Xcode 27.1 / SDK macOS 27.0. Le binaire a été exécuté avec l’accès aux services XPC Speech du système.

## Disponibilité vérifiée

- `SpeechTranscriber.isAvailable`: `true`.
- 45 locales exposées par `SpeechTranscriber.supportedLocales`, dont `fr_FR`; `fr_FR` est aussi dans `installedLocales`.
- `SpeechTranscriber.supportedLocale(equivalentTo: fr-FR)`: `fr_FR`.
- Les formats compatibles annoncent mono 8 kHz et 16 kHz int16.
- `AssetInventory.status` passe de `supported` à `installed` après la réservation de `fr_FR`; la réservation a été relâchée. Aucun téléchargement ni appel à `assetInstallationRequest` n’a été fait.
- Le premier probe lancé dans le sandbox Codex retournait des listes vides. Avec accès XPC local autorisé, les locales et statuts réels sont lisibles. C’était une limitation d’accès du probe sandboxé, pas une absence du modèle français.

## Deux courtes dictées synthétiques

Les deux fichiers ont été générés localement par `say -v Thomas`, en français (`fr_FR`). L’entrée est mono PCM 16 bits à 22,05 kHz. Le harness a converti vers un format accepté, puis envoyé des buffers d’environ 200 ms à la cadence audio. Les résultats mesurent la transcription native seule ; aucun nettoyage Qwen n’est appliqué.

| Test | Référence parlée | Audio | Premier volatile | Premier final | Dernier final après fin audio | CPU du processus appelant |
|---|---|---:|---:|---:|---:|---:|
| Noms propres | Je travaille sur FacilAbo et EuroVolt avec Eric Cologni à Allauch. | 4,295 s | 1 058 ms | 4 391 ms | 90 ms | 0,036 s |
| Reprise | Euh, je passe mardi, non pardon, mercredi matin pour récupérer le dossier. | 5,385 s | 1 030 ms | 5 433 ms | 38 ms | 0,035 s |

Préparation mesurée : 96,8 ms sur le premier run, 34,1 ms sur le second. Finalisation après fermeture du flux : 92,0 ms et 40,2 ms, respectivement.

### Sorties

- Noms : `Je travaille sur Fy Labo eturolt avec Éric Colonia à Loche`
  - `FacilAbo` est transcrit en deux mots erronés, `EuroVolt` est aussi mal reconnu, `Cologni` devient `Colonia`, et `Allauch` devient `Loche`.
- Reprise : `Je passe mardi non pardon, mercredi matin pour récupérer le dossier`
  - Le résultat supprime `Euh` mais conserve `mardi` avant la correction `non pardon, mercredi`. Il transcrit donc la réparation sans effectuer le nettoyage éditorial attendu d’une dictée.

## Lecture et limites

Le premier résultat provisoire apparaît après environ 1,0 s de parole dans les deux cas. Le dernier résultat final arrive 38–90 ms après la fermeture du flux, ce qui montre une finalisation très courte dans ces deux essais synthétiques. Les mesures ne sont pas une comparaison contrôlée avec Whisper : les clips n’ont pas été réenregistrés par une voix humaine et seuls deux exemples très courts ont été passés.

Le CPU indiqué vient de `getrusage(RUSAGE_SELF)` sur le programme appelant. Il ne mesure pas le coût du moteur Speech du système. Apple décrit le modèle `SpeechTranscriber` comme géré par le système et exécuté hors de l’espace mémoire de l’application ; le chiffre CPU du processus n’est donc pas une mesure de consommation globale du moteur ([WWDC25, SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)).

La qualité des noms propres est insuffisante sans correction dans ce test. L’API `AnalysisContext.contextualStrings` documente les termes propres pour `DictationTranscriber`, pas pour `SpeechTranscriber`; voir [AnalysisContext.contextualStrings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings). Aucun test de dictionnaire contextuel n’a été fait. Une prochaine comparaison utile serait `DictationTranscriber` avec les noms du lexique, puis une comparaison Whisper+Qwen sur les mêmes fichiers.
