# Moteur vidéo local

## Portée et format

`Services/VideoRecorder.cs` utilise **ScreenRecorderLib 7.0.1**, dont le moteur natif s'appuie sur Microsoft Media Foundation. Il produit un MP4 H.264 à 30 images/s, avec un débit cible de 6 Mbit/s et le curseur visible. L'encodage matériel est autorisé et la limitation de ressources du moteur reste activée.

La source est explicitement **l'écran principal uniquement**, via `DisplayRecordingSource.MainMonitor`. La définition native de cet écran est conservée. La capture de tous les écrans, d'une caméra ou du microphone n'est jamais ajoutée implicitement. L'interface doit annoncer cette portée avant le démarrage.

Avec `systemAudio: false`, aucune piste ni source audio n'est configurée. Avec `true`, la seule source est `LoopbackAudioSource.Default`, soit le son envoyé au périphérique de lecture système par défaut. Aucun `CaptureAudioSource` n'est créé : le microphone reste désactivé. Le changement de périphérique pendant la capture n'est pas pris en charge par ce wrapper.

## Contrat d'intégration

Créer l'objet et appeler `Start`, `Stop` et `Dispose` sur le thread UI WPF. Les événements `Completed` et `Failed` sont délivrés sur ce même dispatcher. Les rappels natifs sont toujours mis en file avant de libérer le moteur, pour éviter une destruction pendant son propre rappel.

```csharp
var video = new VideoRecorder();
video.Completed += path => { /* Ajouter le fichier final à la bibliothèque. */ };
video.Failed += message => { /* Afficher le message et restaurer l'interface. */ };
video.Start(destinationMp4, systemAudio: false);
// Après l'action explicite « Arrêter » :
video.Stop();
// Attendre Completed ou Failed avant de disposer dans le parcours normal.
```

`IsRecording` reste vrai pendant le démarrage, la capture et la finalisation. `Stop()` demande la fin sans prétendre que le MP4 est déjà prêt ; seul `Completed` signifie qu'il peut être ajouté à la bibliothèque. Un délai de finalisation de 45 secondes produit une erreur plutôt qu'un succès supposé.

L'enregistrement est d'abord écrit dans un fichier unique `.partial.mp4` à côté de la destination. Après le signal de réussite du moteur, le wrapper vérifie les boîtes MP4 `ftyp`, `moov` et `mdat`, leurs tailles et l'absence de troncature ; il renomme alors le fichier sans écraser de fichier existant. Une erreur ou un arrêt de l'application ne déclenche jamais `Completed`. Un éventuel fichier partiel est conservé et son chemin est mentionné dans l'erreur. `Dispose()` pendant une capture libère les ressources mais ne constitue pas un parcours d'enregistrement réussi.

Le wrapper remonte aussi les erreurs synchrones de démarrage par `Failed`. Les appels concurrents ne sont pas autorisés : désactiver le bouton de nouveau départ tant que `IsRecording` est vrai. Un appel `Start` supplémentaire signale une erreur sans annuler la session déjà active.

## Compilation et prérequis

Le projet et le paquet doivent être compilés en **x64**. Les targets NuGet exigent `Platform=x64` ; définir uniquement `PlatformTarget=x64` ne suffit pas. Exemple : `dotnet build -c Release -p:Platform=x64`.

Le moteur natif peut nécessiter le **Microsoft Visual C++ Redistributable x64** et **Media Foundation**. Windows N/KN et Windows Server peuvent ne pas fournir Media Foundation par défaut. Le wrapper affiche une erreur exploitable ; il n'installe rien et ne change pas Windows. La distribution doit contenir la DLL native issue du paquet et conserver son avis de licence MIT.

Les limites restent celles d'une capture d'écran : contenu protégé, bureau sécurisé, session verrouillée ou changement de configuration graphique peuvent interrompre l'enregistrement. La vidéo n'inclut ni découpage, ni webcam, ni transcription.

## Vérification effectuée

Le 28 octobre 2026, un projet isolé WPF `net10.0-windows`, x64, a compilé ce wrapper contre le paquet 7.0.1. Son exécution a vérifié le refus d'une destination non MP4, puis la création et la libération du vrai `Recorder` natif **sans appeler `Record()`**. Aucune image ni piste audio n'a été capturée pendant cette vérification.

Un second test a remplacé la source du moteur par une unique image PNG générée de 640 × 360 pixels, avant tout appel à `Record()`. Il a encodé trois secondes environ en H.264 logiciel, appelé le vrai `Stop()` du wrapper, reçu `Completed` sur le dispatcher UI et produit un MP4 de 4 824 octets. La validation des boîtes MP4 et la promotion du fichier partiel ont réussi. Aucune source d'écran ou audio n'a été enregistrée par ce test.

Le test intégré a ensuite couvert exactement l'écran principal avec une fenêtre de pixels synthétiques avant d'activer la source d'écran réelle, sans audio. La capture avec l'encodage matériel autorisé a produit un MP4 finalisé, puis le décodeur Windows l'a ouvert : 2560 × 1600 pixels et environ une seconde de vidéo pour ce test court. Le test a également confirmé que `IsRecording` redevient faux après finalisation. L'activation de l'option matérielle n'établit pas que le pilote a effectivement choisi le GPU plutôt qu'un repli logiciel. L'audio système et les changements de configuration d'affichage restent à vérifier ; aucune piste micro n'est configurée.

## Sources

- [Projet officiel ScreenRecorderLib et prérequis](https://github.com/sskodje/ScreenRecorderLib)
- [Guide officiel pour la version 7 : sources d'écran, audio et événements](https://github.com/sskodje/ScreenRecorderLib/wiki/Quickstart-guide-v7.x.x-and-newer)
- [Paquet NuGet 7.0.1](https://www.nuget.org/packages/ScreenRecorderLib/7.0.1)
- Métadonnées locales du paquet restauré : `screenrecorderlib.nuspec`, `build/ScreenRecorderLib.targets`, documentation XML et `LICENSE`.

Le fichier `LICENSE` du paquet porte l'avis « Copyright (c) 2017 Sverre Skodje » et la licence MIT ; le nuspec déclare également l'expression de licence MIT. Conserver le texte complet de cette licence dans le paquet de distribution.
