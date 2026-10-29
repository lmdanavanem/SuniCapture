# SuniCapture — direction et architecture

Application Windows de capture locale, inspirée des parcours documentés de Screenpresso et du système visuel du dépôt voisin SUNIPDF. Aucune ressource ni code de Screenpresso n'est réutilisé.

## Direction visuelle

Tokens repris de SUNIPDF/apps/sunipdf-desktop/src/theme.rs : chrome #F8FAFC, surface #FFFFFF, bord #E2E8F0, texte #0F172A, secondaire #64748B, accent #2563EB. Thème sombre : chrome #191E2E, surface #22283A, bord #343C52, texte #F1F5F9. Police Segoe UI, titres 22–28 px, corps 13–14 px, coins 6/8/12 px.

Disposition : titre et navigation supérieurs discrets ; bibliothèque à gauche, grand espace central d'édition, outils contextuels à droite. La capture est l'action dominante. Le premier lancement présente un état vide utilisable, sans fausses captures ni compteurs inventés.

```text
SuniCapture                 Capturer   Importer    Thème
Bibliothèque    | Capture / modes et délai              |
Recherche      | Barre : flèche, forme, texte, masquer | Propriétés
Historique     |                                      | Couleur
Favoris        |              Image                   | Épaisseur
               |                                      | Export
Captures       |                                      |
Stockage local | Taille / zoom / état                  |
```

Les surfaces calmes et les pastilles bleues proviennent du produit existant ; le cadre de visée bleu identifie la nouvelle application. Contrôles clavier, infobulles, focus visibles et erreurs explicites.

Mise à jour du 29 octobre : les deux visuels fournis remplacent le symbole provisoire. Logo complet à l'accueil, icône ruban S pour l'en-tête, la fenêtre, l'exécutable et la zone de notification. Pixels et transparence préservés ; conversion ICO en 16, 24, 32, 48, 64, 128 et 256 px. Les actions gardent le bleu SuniPDF ; la marque Capture reprend le rouge du logo.

## Modules

- `Services/DesktopCapture.cs`, `GlobalHotkeys.cs`, `Windows/RegionSelectorWindow.cs` : capture Win32, sélection et raccourcis, indépendants de la bibliothèque.
- `Editor/AnnotationCanvas.cs`, `Services/ImageExport.cs` : annotations en coordonnées pixels, rendu aplati et exports.
- `Models`, `Services/LibraryStore.cs` : historique JSON atomique et fichiers locaux ; originaux conservés, corbeille réversible.
- `MainWindow` : intégration de la bibliothèque, import, édition, paramètres et capture.
- `Diagnostics` : vérification locale avec images synthétiques, stockage isolé et résultats vérifiables.

Les fonctions livrées et leurs limites sont consignées dans les README français et anglais.

## Alignement SuniPDF — version 0.3.0

L'interface suit celle de [SuniPDF](https://github.com/lmdanavanem/SuniPDF). Le globe choisit la langue ; le point d'interrogation ouvre directement À propos. La présentation reprend un en-tête clair, un logo centré, une pastille de version, des badges de confidentialité, une carte bleue et un corps défilant avec fermeture fixe. Les couleurs suivent le thème existant de SuniCapture.

Les informations restent propres à SuniCapture : Windows x64, bibliothèque locale, moteur ScreenRecorderLib et absence de mise à jour automatique. Aucun contrôle de mise à jour ou de récupération de SuniPDF n'est simulé. La roue dentée conserve les options de capture et ajoute les choix de langue et d'apparence.

`Localization/strings.json` contient les deux traductions de chaque ressource. Les bindings XAML sont rafraîchis sur place ; le changement de langue ne reconstruit ni la fenêtre ni l'éditeur. Les textes saisis et les noms de captures ne sont pas traduits. La préférence `Language` est optionnelle pour les fichiers de réglages des versions précédentes.
