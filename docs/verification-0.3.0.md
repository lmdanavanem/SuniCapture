# Vérification de SuniCapture 0.3.0

Distribution autonome Windows x64 vérifiée le 29 octobre 2026.

- Publication .NET Release réussie ; aucune erreur ou alerte de compilation lors de la génération finale.
- **36 contrôles de base réussis** : annotations, exports, bibliothèque, récupération d'index et conservation des originaux.
- **94 contrôles de parcours réussis** : bibliothèque, éditeur, thèmes, fenêtres À propos / Préférences / Aide, changement FR/EN et enregistrement vidéo réel. Total : **130**.
- **307 ressources FR/EN vérifiées** par `scripts/check-localization.py` : couverture des références littérales, absence de traductions vides et mêmes arguments dans les messages formatés.
- Le changement de langue conserve l'image ouverte, les pixels d'une annotation non enregistrée, l'outil actif, le nom de la capture et le texte saisi. La préférence anglaise est relue par le stockage et par le code de démarrage.
- Enregistrer les préférences applique la langue sans redémarrage. Annuler conserve la langue, le thème et les options précédents. Les réglages anciens sans langue restent compatibles avec le français.
- Les dialogues sont vérifiés en français et en anglais, en clair et en sombre, avec la fenêtre principale à 1100 × 700. Leur contenu défile avec un pied de page fixe ; les raccourcis globaux de capture restent bloqués derrière les dialogues.
- La touche Échap est vérifiée par le routage d'un événement clavier WPF vers le dialogue : il se ferme sans modifier les préférences.
- Le parcours vidéo finalise un MP4 depuis un écran couvert par une image synthétique, l'indexe et l'ouvre dans l'aperçu. Le décodeur Windows lit une vidéo de **2560 × 1600, 2 secondes**. Aucun microphone ou son système n'est utilisé dans ce test.

Contrôle de l'interface Windows : lancement de la distribution en anglais, ouverture de À propos par le bouton ?, défilement, accès aux préférences, fermeture par Annuler, sélection du français par le globe et ouverture de l'aide par F1. Les captures rendues par le banc UI complètent ces observations avec les thèmes et les tailles minimales.

Tous les processus de test utilisent des bibliothèques isolées. La bibliothèque personnelle n'est pas utilisée pour ces tests. La conservation des originaux est vérifiée par comparaison des pixels et des sommes SHA-256.

Le [résumé JSON de vérification](verification-0.3.0.json) conserve les résultats des contrôles sans les chemins propres au poste de test. Les commandes permettant de reproduire les contrôles sont décrites dans le [guide de développement](development.md).

La vidéo avec audio système et les configurations de plusieurs écrans avec DPI différents gardent les limites de qualification de la version précédente.
