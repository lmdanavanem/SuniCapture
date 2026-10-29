# SuniCapture 0.3.0 — Français, anglais et À propos

Version Windows x64 du 29 octobre 2026. Les fonctions de capture, d'annotation, d'export et d'enregistrement restent celles de la version 0.2.0.

- Bouton globe FR/EN, langue appliquée immédiatement et enregistrée dans les préférences.
- Traduction de l'interface, des menus, des infobulles, des noms accessibles, des dialogues et des messages applicatifs.
- Bouton ? ouvrant À propos sur le modèle de SuniPDF : logo, version de l'exécutable, confidentialité, stockage, personnalisation et licences.
- Préférences avec langue et thème clair/sombre, ainsi que les options existantes de copie, zone de notification et audio système.
- Guide intégré avec raccourcis, accessible par F1 ou depuis À propos.
- Documentation française et anglaise incluse dans la distribution portable.

Le changement de langue conserve l'image ouverte, les annotations en cours, l'outil actif, les noms et textes utilisateur. Les préférences anciennes sans champ de langue restent compatibles et utilisent le français. Aucune vérification en ligne des mises à jour n'est implémentée ; le dialogue l'indique explicitement.

Les données restent sous `%LOCALAPPDATA%\SuniCapture`, indépendamment du dossier portable. Pour mettre à jour, quittez l'ancienne version depuis son icône de notification, puis utilisez le nouveau dossier portable. Depuis un dépôt compilé, le lanceur à la racine ouvre `dist/SuniCapture-0.3.0-win-x64/SuniCapture.exe`.

Les vérifications de cette version sont consignées dans le [bilan de vérification](verification-0.3.0.md). Voir également l'[historique des versions](../CHANGELOG.md).
