FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-gi python3-gi-cairo python3-cairo python3-gst-1.0 \
    gir1.2-gtk-3.0 gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-ugly gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-gtk3 \
    gstreamer1.0-pipewire ffmpeg pulseaudio-utils dbus-x11 xvfb xauth openbox \
    fonts-dejavu-core desktop-file-utils ca-certificates dpkg-dev x11-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
