# Développement

## Linux

Le client natif se trouve dans `src/SuniCapture.Linux`. Il utilise Python 3.10+, GTK 3, Cairo, FFmpeg et GStreamer fournis par le système. La bibliothèque locale est indépendante du dossier de l'application. Les traductions partagées sont complétées par les ressources Linux.

Le [guide Linux](linux.md) décrit les dépendances, la compilation du `.deb` et de l'archive ainsi que les tests dans un bureau Xvfb isolé. `scripts/build-linux.py` vérifie l'alignement des versions Windows/Linux et compile les sources Python avant de créer les paquets. Les workflows Linux valident les paquets sur Ubuntu.

## macOS

Le client natif se trouve dans `src/SuniCapture.macOS` : paquet Swift (Swift 6.2, Xcode 26 ou plus récent), SwiftUI pour l'interface, AppKit pour l'éditeur, le sélecteur de zone, les menus et l'icône de barre des menus, ScreenCaptureKit pour les captures et la vidéo, Carbon pour les raccourcis globaux. Il reprend `src/SuniCapture/Localization/strings.json` et ajoute les textes macOS dans `Resources/strings.macos.json` ; les libellés `Ctrl+…` y sont réécrits en `⌃⇧`/`⌘` au chargement.

| Fichier | Responsabilité |
|---|---|
| `AppModel.swift` | Logique de la fenêtre principale : bibliothèque, capture, édition, vidéo, préférences |
| `Library.swift` | Index JSON et réglages compatibles Windows/Linux, écriture atomique, `.bak`, récupération |
| `Images.swift` | Import ImageIO, exports aplatis PNG/JPEG/BMP/PDF, presse-papiers |
| `Capture.swift` | ScreenCaptureKit, sélecteur de zone sur image figée, compte à rebours, raccourcis ⌃⇧1–4 |
| `Editor.swift` | Annotations en pixels, historique, rendu aplati, zoom |
| `Recorder.swift` | MP4 H.264 par `SCRecordingOutput`, validation `ftyp`/`moov`/`mdat`, barre d'arrêt flottante |
| `Views.swift`, `Dialogs.swift` | Interface et dialogues, mêmes jetons visuels que Windows |
| `Diagnostics.swift` | `--self-test` (bibliothèque, éditeur, exports) et `--ui-self-test` (parcours, capture, vidéo) |

`scripts/build-macos.sh` lit la version du `.csproj`, construit l'application universelle, la signe (ad hoc, ou `SUNICAPTURE_SIGN_IDENTITY`), exécute `--self-test` et produit le `.dmg` et `SHA256SUMS-macos.txt`. `--ui-checks` lance l'application par LaunchServices pour que l'autorisation d'enregistrement de l'écran lui soit attribuée. Le workflow `macos-build.yml` construit et vérifie le paquet. Voir le [guide macOS](macos.md).

La suite ci-dessous concerne le client Windows.

## Environnement

- Windows x64 et .NET SDK 10.
- Python 3 pour vérifier les traductions.
- Accès NuGet lors de la restauration de ScreenRecorderLib 7.0.1.

## Compilation

```powershell
dotnet build src/SuniCapture/SuniCapture.csproj -c Release
./scripts/build.ps1
```

`build.ps1` génère l'icône Windows, publie une distribution autonome, conserve les licences des dépendances, exécute les tests de base, puis produit un ZIP et `SHA256SUMS.txt` sous `dist/`. Le numéro de version vient du fichier projet.

`-RunUiChecks` ajoute les tests des fenêtres et de la vraie capture vidéo. Ils exigent un bureau Windows interactif et affichent brièvement une fenêtre synthétique sur l'écran principal, sans audio. `-SkipTests` est réservé aux reconstructions dont les contrôles sont exécutés séparément ; il ne peut pas être combiné avec `-RunUiChecks`.

## Vérifications isolées

```powershell
python scripts/check-localization.py
./dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe --self-test --data-dir ./artifacts/qa-data/manual
./dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe --ui-self-test --data-dir ./artifacts/qa-data/manual-ui
```

Les rapports JSON et les images sont écrits dans le dossier de test choisi. Ne choisissez pas votre bibliothèque personnelle comme dossier de test. Les données de test, compilations et distributions ne sont pas suivies par Git.

Chaque invocation de `build.ps1 -RunUiChecks` utilise une bibliothèque neuve. Un échec du test produit un code de retour non nul et bloque la génération de l'archive.

Le workflow Windows vérifie les traductions, construit la distribution et exécute les tests de stockage et d'export. Il publie le ZIP, les sommes de contrôle et les rapports de test comme artefacts de compilation. Les tests vidéo demandant un bureau interactif sont exécutés localement avant une release.

## Organisation

| Chemin | Responsabilité |
|---|---|
| `src/SuniCapture/MainWindow*` | Interface, bibliothèque, préférences et intégration des parcours |
| `src/SuniCapture/Services` | Capture Windows, stockage local, export, raccourcis et vidéo |
| `src/SuniCapture/Editor` | Annotations en coordonnées pixels et rendu aplati |
| `src/SuniCapture/Windows` | Sélection visuelle d'une zone |
| `src/SuniCapture/Localization` | Ressources françaises/anglaises et changement de langue |
| `src/SuniCapture/Diagnostics` | Données synthétiques et vérifications des parcours |
| `assets` | Logo, icône source et icône Windows multirésolution |

## Préparer une version

1. Modifier la version du fichier projet et mettre à jour le changelog, les README et le lanceur.
2. Exécuter le contrôle des traductions et `./scripts/build.ps1 -RunUiChecks` sur un bureau Windows interactif.
3. Vérifier la réussite du workflow Windows pour le commit à publier.
4. Créer le tag correspondant et joindre le ZIP ainsi que `SHA256SUMS.txt` à la release.
5. Vérifier les téléchargements publiés et leurs sommes SHA-256.

Les données utilisateur restent sous `%LOCALAPPDATA%\SuniCapture`, indépendamment du dossier portable. Une version ne doit pas déplacer, purger ou écraser la bibliothèque lors d'une mise à jour.
