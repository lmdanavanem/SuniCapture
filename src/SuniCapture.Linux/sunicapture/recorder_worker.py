"""Separate GStreamer process: EOS must complete before an MP4 is promoted."""
import argparse
import json
import signal
import sys

import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", required=True)
    parser.add_argument("--display")
    parser.add_argument("--rectangle", nargs=4, type=int)
    parser.add_argument("--pipewire-fd", type=int)
    parser.add_argument("--node", type=int)
    parser.add_argument("--serial")
    parser.add_argument("--audio-monitor")
    args = parser.parse_args()
    Gst.init(None)
    pipeline = Gst.Pipeline.new("sunicapture-recording")

    def element(factory, name, **properties):
        created = Gst.ElementFactory.make(factory, name)
        if created is None:
            raise RuntimeError("Missing GStreamer component: " + factory)
        for key, value in properties.items():
            created.set_property(key.replace("_", "-"), value)
        pipeline.add(created)
        return created

    def link(*elements):
        for first, second in zip(elements, elements[1:]):
            if not first.link(second):
                raise RuntimeError("Could not link recording components.")

    try:
        if args.pipewire_fd is not None:
            source = element("pipewiresrc", "screen", fd=args.pipewire_fd, do_timestamp=True)
            properties = {prop.name for prop in source.list_properties()}
            if args.serial and "target-object" in properties:
                source.set_property("target-object", args.serial)
            else:
                source.set_property("path", str(args.node))
        else:
            source = element("ximagesrc", "screen", display_name=args.display, use_damage=False, show_pointer=True)
            if args.rectangle:
                x, y, width, height = args.rectangle
                for prop, value in (("startx", x), ("starty", y), ("endx", x + width - 1), ("endy", y + height - 1)):
                    source.set_property(prop, value)
        queue = element("queue", "video-input")
        convert = element("videoconvert", "convert")
        rate = element("videorate", "rate")
        caps = element("capsfilter", "format", caps=Gst.Caps.from_string("video/x-raw,format=I420,framerate=30/1"))
        encoder = element("x264enc", "encoder", bitrate=6000, speed_preset="ultrafast", tune="zerolatency")
        parser_element = element("h264parse", "parser")
        output_queue = element("queue", "video-output")
        muxer = element("mp4mux", "muxer", faststart=True)
        sink = element("filesink", "file", location=args.path)
        link(source, queue, convert, rate, caps, encoder, parser_element, output_queue, muxer, sink)
        if args.audio_monitor:
            audio = element("pulsesrc", "system-audio", device=args.audio_monitor, do_timestamp=True)
            audio_convert = element("audioconvert", "audio-convert")
            audio_rate = element("audioresample", "audio-rate")
            audio_encoder = element("avenc_aac", "audio-encoder", bitrate=128000)
            audio_queue = element("queue", "audio-output")
            link(audio, audio_convert, audio_rate, audio_encoder, audio_queue, muxer)
    except Exception as error:
        print(json.dumps({"event": "error", "message": str(error)}), flush=True)
        return 1

    loop = GLib.MainLoop()
    state = {"started": False, "success": False, "stopping": False, "timeout": None}

    def stop(*_):
        if not state["stopping"]:
            state["stopping"] = True
            pipeline.send_event(Gst.Event.new_eos())
            state["timeout"] = GLib.timeout_add_seconds(40, loop.quit)
        return False

    def message(bus, event):
        if event.type == Gst.MessageType.ERROR:
            error, debug = event.parse_error()
            print(json.dumps({"event": "error", "message": str(error)}), flush=True)
            loop.quit()
        elif event.type == Gst.MessageType.EOS:
            state["success"] = True
            loop.quit()
        elif event.type == Gst.MessageType.STATE_CHANGED and event.src == pipeline:
            old, new, pending = event.parse_state_changed()
            if new == Gst.State.PLAYING and not state["started"]:
                state["started"] = True
                print(json.dumps({"event": "started"}), flush=True)

    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect("message", message)
    signal.signal(signal.SIGINT, lambda *_: GLib.idle_add(stop))
    signal.signal(signal.SIGTERM, lambda *_: GLib.idle_add(stop))
    startup_timeout = GLib.timeout_add_seconds(25, lambda: False if state["started"] else (loop.quit() or False))
    pipeline.set_state(Gst.State.PLAYING)
    try:
        loop.run()
    finally:
        pipeline.set_state(Gst.State.NULL)
        bus.remove_signal_watch()
        if state["timeout"]:
            GLib.source_remove(state["timeout"])
    print(json.dumps({"event": "finished", "success": state["success"]}), flush=True)
    return 0 if state["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
