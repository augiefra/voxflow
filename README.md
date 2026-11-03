<div align="center">

<img src="assets/voxflow-icon.png" width="112" alt="VoxFlow icon">

# VoxFlow

**Hold Fn, speak, it types. Private dictation that runs entirely on your Mac.**

[![Download for macOS](https://img.shields.io/badge/Download-for%20macOS-111111?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/augiefra/voxflow/releases/latest)
&nbsp;
[![More apps by Eric](https://img.shields.io/badge/More%20apps%20by%20Eric-App%20Store-0D84FF?style=for-the-badge&logo=appstore&logoColor=white)](https://apps.apple.com/fr/developer/eric-cologni/id1853633356)

![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-macOS%2014%2B-555?style=flat-square)
![Notarized](https://img.shields.io/badge/signed%20%26%20notarized-Developer%20ID-555?style=flat-square)
![Auto-updates](https://img.shields.io/badge/updates-Sparkle-555?style=flat-square)
![License MIT](https://img.shields.io/badge/license-MIT-555?style=flat-square)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/voxflow-demo-dark.gif">
  <img src="assets/voxflow-demo.gif" width="560" alt="The VoxFlow pill: listening, hands-free lock, formatting, then a learned word">
</picture>

</div>

**New in [VoxFlow 0.1.6](https://github.com/augiefra/voxflow/releases/tag/v0.1.6):** faster local dictation with Parakeet, preparation while you speak after inactivity, and more selective Qwen cleanup. On 30 synthetic French clips on an M4 Pro, median engine time after release went from 1.34 s to 0.19 s, before paste. See the [measurements and limits](docs/PERFORMANCE.md).

## Why VoxFlow

| | |
| --- | --- |
| 🔒 **Private by design** | Your voice is transcribed on your Mac. No account, no cloud, no audio or text leaves the machine. |
| ⚡ **Fast** | Transcription work starts at clear pauses; text is pasted when you finish. Optional formatting has a short shared budget. See the [measured runs](docs/PERFORMANCE.md). |
| 🧠 **Learns your words** | Eligible corrections made just after dictation become local vocabulary rules, confirmed by the green “Learned” bubble. |
| 🎙 **Two ways to talk** | Hold Fn while you speak, or press it twice to go hands-free and once more to finish. Prefer right ⌘, ⌥ or ⌃? Pick it in Settings. |
| 🔇 **Quiet while you talk** | Music and videos are muted while you dictate, then come back. |
| 🆓 **Free** | Open source under the MIT license, signed, notarized and kept up to date automatically. |

## Install

1. [Download the latest VoxFlow DMG](https://github.com/augiefra/voxflow/releases/latest) and drag VoxFlow to Applications.
2. Open VoxFlow. A short welcome walks you through the rest, no Terminal needed:
   - Parakeet TDT v3 (2.51 GB) starts downloading right away; then choose **Full** to add Qwen3.5 (3.06 GB more, 5.57 GB total) or **Light** (transcription only, for 8 GB Macs or a nearly full disk);
   - allow **Microphone** and **Accessibility**: VoxFlow restarts itself once Accessibility is on, so the key works right away, and the welcome picks up where it left off;
   - choose your dictation key: **Fn** (🌐), or right **⌘**, **⌥** or **⌃**. With Fn, set **System Settings › Keyboard › Press 🌐 key to** → **Do Nothing**; the welcome checks it for you;
   - try it in the welcome window.

VoxFlow lives in the menu bar. The first launch needs an internet connection to fetch Python and its packages (about 150 MB, installed by the bundled [uv](https://docs.astral.sh/uv/)) and the models from Hugging Face. After that it works offline. Python, the engine's packages, the models and your learned words live in `~/.voxflow`; your settings (dictation key, mode) live in the app's preferences.

**Requirements:** a Mac with Apple Silicon and macOS 14 or later. VoxFlow currently applies memory thresholds of 16 GB for Full mode and 8 GB for Light mode. These are guardrails, not peak-memory measurements for the current models.

## How it works

```
Fn ──► microphone ──► Parakeet TDT 0.6B v3 (speech to text at pauses)
                         │
                         ▼
              Qwen3.5 4B (optional text cleanup)
                         │
                         ▼
             pasted at your cursor ──► your corrections are learned
```

- **Parakeet TDT 0.6B v3** transcribes a segment after at least 1.5 seconds of audio followed by a clear 400 ms pause, or at a 28-second safety limit. It does not show partial words while you speak. Simple “euh”, “heu” and “hum” fillers are removed locally.
- **Qwen3.5 4B** runs after you finish dictating, then cleans up repetitions, false starts and context-dependent vocabulary when needed. Its shared cleanup budget is 1.5 seconds; if it runs out, VoxFlow uses the local fallback. Light mode leaves Qwen out.
- After pasting, VoxFlow watches the field for 25 seconds. When you replace a misheard word, the fix goes into a local dictionary used by later cleanup; with Whisper selected, canonical terms also enter its recognition prompt.
- Whisper and Voxtral remain available as ASR choices through `--asr-model`; Parakeet is the default.
- Everything runs with Apple's [MLX](https://github.com/ml-explore/mlx) on the GPU of your Mac.

Correction learning follows the field for up to 25 seconds, ending when you submit, change focus or begin another dictation. Only short, plausible vocabulary substitutions are stored; replacing most of a short title can still be ignored. Check **Learned words** in the menu to see what was retained. The speech engine and these local rules are separate: a learned spelling corrects the transcription during cleanup.

VoxFlow is built and tuned for **French**. Other languages are untested for now.

## Privacy

- The speech engine listens only on `127.0.0.1`, behind a random token, and refuses requests from web pages.
- Keystrokes are only observed for 25 seconds after a paste, in memory, to learn your corrections. Password fields are never read.
- The learned dictionary stays in `~/.voxflow/lexicon.db`, and you can forget any entry from the menu.
- Your last five dictations stay in memory (never on disk) under Recent Dictations in the menu: if a paste landed in the wrong place, click one to paste it again.
- The engine log (`~/.voxflow/daemon.log`) keeps durations and lengths, never what you dictate. Text written there by version 0.1.0 is masked, including in « Copy log ».
- Update checks fetch a signed feed from this repository. Nothing about you is sent.
- The only other downloads happen once, at first launch: Python and its packages (python-build-standalone and PyPI, via uv) and the models from Hugging Face, each file checked against its expected size and SHA-256.

## Uninstall

Quit VoxFlow from the menu bar, delete the app, then remove its data, Python and models, and its settings:

```bash
rm -rf ~/.voxflow
```

```bash
defaults delete com.ericcologni.voxflow
```

If you used version 0.1.0, its Voxtral and Qwen2.5 files may still be in the Hugging Face cache. They are not the current defaults; Voxtral can still be selected explicitly with `--asr-model`. Delete those cache entries only when you no longer need them:

```bash
rm -rf ~/.cache/huggingface/hub/models--mlx-community--Voxtral-Mini-4B-Realtime-2602-4bit ~/.cache/huggingface/hub/models--mlx-community--Qwen2.5-Coder-7B-Instruct-4bit
```

## Build from source

```bash
git clone https://github.com/augiefra/voxflow.git
cd voxflow
macos/scripts/build_app.sh --install
```

You need a recent Xcode (VoxFlow is developed with Xcode 27). The script builds a release, downloads uv (pinned version, checksum verified), bundles it with the speech engine, the English and French strings and Sparkle, signs the app with your own developer identity and installs it in `~/Applications`. Tests: `swift test --package-path macos`, and in `daemon/`, with [uv](https://docs.astral.sh/uv/) installed (or the copy the build script downloads to `macos/.build/uv-0.12.24/uv`): `uv run --frozen python -m unittest test_inference_daemon test_model_store`.

The full technical documentation, in French, is in [docs/TECHNIQUE.md](docs/TECHNIQUE.md).

## Credits

VoxFlow stands on the work of others:

- [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by NVIDIA, converted to MLX by [mlx-community](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/tree/ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15), CC BY 4.0
- [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) by the Qwen team at Alibaba Cloud, Apache 2.0
- [Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo), MIT; retained as an optional ASR engine
- [Voxtral Mini 4B Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) by Mistral AI, Apache 2.0; retained as an optional ASR engine
- [MLX](https://github.com/ml-explore/mlx), [mlx-audio](https://github.com/Blaizzy/mlx-audio) and [mlx-lm](https://github.com/ml-explore/mlx-lm), MIT, with 4-bit conversions by [mlx-community](https://huggingface.co/mlx-community)
- [uv](https://github.com/astral-sh/uv) by Astral, bundled to install Python and the engine's packages, MIT or Apache 2.0
- [Sparkle](https://sparkle-project.org) for updates, MIT

Every third-party license is listed in [THIRD_PARTY_NOTICES.txt](macos/Resources/THIRD_PARTY_NOTICES.txt) and in the app menu.

## En français

VoxFlow est une dictée vocale gratuite et 100 % locale pour Mac. Maintiens **Fn** (ou ⌘, ⌥, ⌃ de droite) pour dicter, ou appuie deux fois pour parler mains libres : Parakeet transcrit les segments, Qwen3.5 les met en forme au besoin, puis VoxFlow colle le texte au curseur. Les téléchargements de modèles représentent 2,51 Go en mode léger ou 5,57 Go en mode complet. VoxFlow apprend ton vocabulaire à partir de tes corrections, et rien ne quitte ton Mac. L'interface est en français et en anglais ; l'accueil installe les moteurs, les autorisations et la touche choisie. [Télécharger la dernière version](https://github.com/augiefra/voxflow/releases/latest) · [Documentation technique](docs/TECHNIQUE.md)

## More apps by Eric

I'm an indie developer in France. If VoxFlow saves you time, the nicest thank-you is to try one of my apps.

<table>
<tr>
<td align="center" width="33%">
<a href="https://apps.apple.com/fr/app/facilabo-de-230-calendriers/id6756318719"><img src="assets/facilabo-icon.png" width="72" alt="FacilAbo"></a><br>
<b>FacilAbo</b><br>
<sub>230+ calendars to subscribe to on iPhone: holidays, school breaks, tax deadlines, sports.</sub><br>
<sub>★ 4.9 · iPhone</sub>
</td>
<td align="center" width="33%">
<a href="https://apps.apple.com/fr/app/eurovolt-conso-%C3%A9lectricit%C3%A9/id6761270150"><img src="assets/eurovolt-icon.png" width="72" alt="EuroVolt"></a><br>
<b>EuroVolt</b><br>
<sub>Your Linky meter in euros, day by day, with home-screen widgets.</sub><br>
<sub>iPhone · France</sub>
</td>
<td align="center" width="33%">
<a href="https://apps.apple.com/fr/app/pastscreen/id6755425479"><img src="assets/pastscreen-icon.png" width="72" alt="PastScreen"></a><br>
<b>PastScreen</b><br>
<sub>Ultra-fast, clipboard-first screenshots for developers.</sub><br>
<sub>Mac</sub>
</td>
</tr>
</table>

<div align="center">

[**See all my apps on the App Store →**](https://apps.apple.com/fr/developer/eric-cologni/id1853633356)

<sub>VoxFlow · MIT License · © 2026 Eric Cologni</sub>

</div>
