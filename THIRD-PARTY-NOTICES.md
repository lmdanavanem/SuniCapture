# SuniCapture components

## Linux system components

The Linux application uses Python 3, PyGObject, GTK 3, Cairo, GStreamer, FFmpeg, X11 and the desktop's portal/PipeWire services. These libraries and tools are installed by the operating system's package manager and are not bundled in the Linux archive or Debian package. Their own copyright and license files remain with the system packages, generally under `/usr/share/doc/<package>/copyright` on Debian/Ubuntu.

Component documentation: [Python](https://docs.python.org/3/), [GTK](https://docs.gtk.org/gtk3/), [Cairo](https://www.cairographics.org/), [GStreamer](https://gstreamer.freedesktop.org/documentation/), [FFmpeg](https://ffmpeg.org/documentation.html), [desktop portals](https://flatpak.github.io/xdg-desktop-portal/docs/).

The Windows components below are not included in the Linux distribution. Component licenses do not grant a separate license for SuniCapture application code.

## Windows components

SuniCapture est une reconstruction indépendante. Screenpresso est une marque de Learnpulse. Aucun code ni ressource de ce produit n'est distribué ici.

## ScreenRecorderLib 7.0.1

Moteur vidéo Windows, licence MIT. Copyright (c) 2017 Sverre Skodje.

Le texte complet est inclus dans `licenses/ScreenRecorderLib-MIT.txt`. Source : https://github.com/sskodje/ScreenRecorderLib ; paquet : https://www.nuget.org/packages/ScreenRecorderLib/7.0.1.

## Microsoft .NET 10 et Windows Desktop

La distribution portable inclut le runtime .NET et WPF fournis par Microsoft. Leurs licences et notices sont conservées sous `licenses/dotnet-LICENSE.txt` et `licenses/dotnet-ThirdPartyNotices.txt`.

Le moteur vidéo utilise les composants Windows Media Foundation et peut nécessiter le runtime Visual C++ x64 déjà présent sur ce poste. Aucun prérequis système n'est installé silencieusement.
