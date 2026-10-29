<p align="center"><img src="assets/Brand/sunicapture-logo.png" width="190" alt="SuniCapture"></p>

# SuniCapture

**Capturez, annotez et enregistrez votre écran, en local.**

Application Windows x64 de capture d'écran, d'annotation et d'enregistrement vidéo MP4. Interface en français et en anglais, thèmes clair et sombre, bibliothèque locale. Aucun compte, aucune télémétrie applicative, aucun envoi de captures.

[Télécharger la dernière version](https://github.com/lmdanavanem/SuniCapture/releases/latest) · [Toutes les versions](https://github.com/lmdanavanem/SuniCapture/releases) · [English](README.md) · [Signaler un problème](https://github.com/lmdanavanem/SuniCapture/issues)

![Accueil de SuniCapture](docs/images/home.png)

Le logo et l'icône sont intégrés dans l'accueil, l'en-tête, la fenêtre, l'exécutable et la zone de notification. Les visuels sont regroupés sous `assets/Brand` ; l'icône Windows est une conversion multirésolution avec transparence.

## Télécharger et lancer

1. Téléchargez **SuniCapture-0.3.0-win-x64.zip** depuis la [release 0.3.0](https://github.com/lmdanavanem/SuniCapture/releases/tag/v0.3.0).
2. Extrayez **tout le dossier** dans un emplacement de votre choix.
3. Ouvrez **SuniCapture.exe** dans le dossier extrait.

La distribution inclut .NET et ne demande pas de droits administrateur. Conservez tous les fichiers du dossier à côté de l'exécutable. Pour vérifier l'archive, comparez le résultat de cette commande au fichier **SHA256SUMS.txt** joint à la release :

```powershell
Get-FileHash .\SuniCapture-0.3.0-win-x64.zip -Algorithm SHA256
```

## Lancer depuis les sources

Double-cliquez sur **Lancer SuniCapture.cmd**, ou ouvrez **dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe**.

La version portable contient .NET : aucune installation de .NET n'est nécessaire. Pour la déplacer sur un autre PC, copiez **tout le dossier** `SuniCapture-0.3.0-win-x64`, ou décompressez `dist/SuniCapture-0.3.0-win-x64.zip`. La bibliothèque existante est conservée.

## Langue, personnalisation et À propos

Le **globe FR/EN**, dans la barre supérieure, bascule immédiatement entre le français et l'anglais. Le choix est conservé au prochain lancement. Les noms des captures et le texte saisi dans les annotations restent tels que vous les avez écrits.

Le bouton **?** ouvre **À propos de SuniCapture**, comme dans SuniPDF : logo, version réelle de l'exécutable, confidentialité, bibliothèque locale, accès aux préférences et licences des composants. La rubrique des mises à jour décrit le fonctionnement de cette version portable ; aucun service de mise à jour automatique n'est ajouté.

La **roue dentée** ouvre les préférences : langue, thème clair ou sombre et options de capture existantes. **Enregistrer les préférences** applique les changements sans redémarrer ; **Annuler** les abandonne. **F1**, ou **Aide et raccourcis** dans À propos, ouvre le guide intégré. Échap ferme les dialogues. La fermeture du dialogue À propos reste disponible pendant le défilement.

## Enregistrer une vidéo de l'écran

1. Cliquez sur **Enregistrer l’écran**, dans la barre supérieure ou la navigation de gauche.
2. Activez le son de l'ordinateur si souhaité, puis cliquez sur **Démarrer l’enregistrement**.
3. Après le compte à rebours, l'écran principal est enregistré. Le bouton flottant **Arrêter** et **Ctrl+Maj+4** terminent la vidéo. Si vous rouvrez la fenêtre, **Arrêter et sauvegarder** est aussi disponible.
4. Attendez la finalisation : le MP4 apparaît dans la bibliothèque et son aperçu s'ouvre. **Exporter le MP4** permet d'en enregistrer une copie où vous voulez.

Le raccourci global Ctrl+Maj+4 démarre aussi directement la vidéo avec les préférences choisies. L'écran dédié indique l'état de la capture et sa durée ; le démarrage est désactivé pendant un enregistrement ou sa finalisation.

## Fonctions disponibles

![Éditeur de SuniCapture](docs/images/editor.png)

- Capture d'une zone avec sélection visuelle, du bureau complet et d'une fenêtre choisie.
- Délai de 0, 3, 5 ou 10 secondes ; Échap annule la sélection.
- Import PNG, JPEG, BMP, TIFF et GIF (première image), dépôt de fichiers et collage d'image.
- Bibliothèque persistante, vignettes, recherche, noms, favoris et corbeille restaurable.
- Flèches, rectangle, ellipse, crayon, surlignage, texte et étapes numérotées.
- Masquage opaque : les pixels masqués sont absents de l'image exportée. L'original reste accessible dans la bibliothèque.
- Recadrage, zoom, ajustement, annuler/rétablir ; les annotations s'enregistrent automatiquement après 800 ms.
- Export des pixels aplatis vers PNG, JPEG, BMP et PDF une page ; copie de l'image annotée.
- Vidéo de l'écran principal en MP4 H.264, 30 i/s, curseur inclus et son du système facultatif. Microphone désactivé.
- Thèmes clair et sombre, préférences persistantes et accès par la zone de notification.

Les fichiers sont conservés dans `%LOCALAPPDATA%\SuniCapture` : `originals`, `edited`, `videos`, `library.json`, `settings.json`. La sauvegarde de l'index précédent porte l'extension `.bak`. Une capture mise dans la corbeille reste restaurable ; aucune purge automatique n'est effectuée. Aucun compte, télémétrie applicative ou envoi de captures n'est implémenté.

Fermer la fenêtre la réduit par défaut dans la zone de notification. Pour arrêter l'application, choisissez **Quitter** dans son icône de notification, ou désactivez cette préférence dans les paramètres.

## Raccourcis

| Action | Raccourci |
|---|---|
| Capturer une zone | Ctrl+Maj+1 |
| Capturer tous les écrans | Ctrl+Maj+2 |
| Choisir une fenêtre | Ctrl+Maj+3 |
| Démarrer / arrêter la vidéo | Ctrl+Maj+4 |
| Importer / coller | Ctrl+O / Ctrl+V |
| Enregistrer / exporter | Ctrl+S / Ctrl+E |
| Copier l'image annotée | Ctrl+C |
| Annuler / rétablir | Ctrl+Z / Ctrl+Y |
| Outils | V pointeur, A flèche, R rectangle, O ellipse, P crayon, H surligner, T texte, N étape, B masquer, C recadrer |

Les raccourcis d'outils s'appliquent hors des champs de saisie. Un conflit de raccourci global est signalé ; les boutons restent disponibles.

## Limites de cette version

La capture défilante, l'OCR, les documents multipages, la webcam, le découpage vidéo et les destinations cloud ne sont pas inclus. Cette version fournit les parcours principaux de capture et d'annotation ; elle ne revendique pas une parité intégrale avec Screenpresso.

La capture d'une fenêtre la met au premier plan et lit ses pixels visibles. Elle ne reconstitue pas une fenêtre masquée ou un contenu protégé. Les écrans HDR peuvent produire un rendu différent avec la capture GDI. La sélection utilise des coordonnées physiques et un manifeste PerMonitorV2 ; la configuration réelle avec plusieurs écrans de DPI différents reste à qualifier.

Les annotations enregistrées sont aplaties ; après réouverture, les objets individuels ne sont pas resélectionnables. L'annulation est disponible pendant la session d'édition. **Revenir à l'original** recharge toujours le fichier initial. Les préférences et captures ne sont pas chiffrées par l'application ; elles suivent les droits Windows du compte local.

Sur Windows N/KN, Media Foundation peut manquer. Sur un autre PC, le moteur vidéo peut nécessiter le runtime Microsoft Visual C++ x64. Ces prérequis ne sont jamais installés automatiquement. Les captures d'image fonctionnent indépendamment du moteur vidéo. Le son système est facultatif et doit être vérifié avec le périphérique utilisé ; aucun test ne capte le microphone.

## Développement et vérification

Prérequis de compilation : Windows x64, .NET SDK 10 et accès NuGet pour restaurer ScreenRecorderLib 7.0.1.

```powershell
dotnet build src/SuniCapture/SuniCapture.csproj -c Release
./scripts/build.ps1
# Ajoute les parcours d'interface et la vraie capture vidéo de test
./scripts/build.ps1 -RunUiChecks
```

`build.ps1` publie une distribution autonome, vérifie ses exports et sa bibliothèque, copie les licences et produit le ZIP portable et ses sommes SHA-256.

```powershell
# Tests de fichiers et de stockage, sans toucher à la bibliothèque personnelle
./dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe --self-test --data-dir ./artifacts/qa-data/manual

# Rendu des écrans + parcours intégrés + MP4 d'un écran couvert par une image synthétique, sans audio
./dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe --ui-self-test --data-dir ./artifacts/qa-data/manual-ui
```

Les rapports et images se trouvent dans le dossier de test choisi. Le test UI vérifie aussi le changement FR/EN avec une annotation non enregistrée, la persistance de la langue, les dialogues clairs/sombres et l'annulation des préférences. Il utilise une image fictive et affiche brièvement une fenêtre plein écran pour que le bureau personnel ne soit pas enregistré. Les tests ne modifient pas le presse-papiers. `python scripts/check-localization.py` vérifie les ressources FR/EN et les paramètres des messages.

La validation locale de la version 0.3.0 compte **130 contrôles réussis** et **307 ressources FR/EN vérifiées**. La validation continue exécute les contrôles de traduction, de compilation, d'export et de stockage ; les parcours vidéo sont testés localement sur un bureau Windows interactif.

Voir le [guide de développement](docs/development.md), le [bilan de vérification](docs/verification-0.3.0.md), le [moteur vidéo](docs/video-engine.md), la [conception de l'interface](docs/design.md) et l'[historique des versions](CHANGELOG.md).

## Composants

SuniCapture est développé par Suniworks. ScreenRecorderLib est distribué sous licence MIT ; les avis .NET et les licences des composants accompagnent la version portable. Voir [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
