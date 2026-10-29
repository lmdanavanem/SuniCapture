from pathlib import Path
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

from .runtime import L, dispatch


def monitor_source():
    result = subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True, timeout=5)
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError(L.t("linux.audioUnavailable"))
    expected = result.stdout.strip() + ".monitor"
    sources = subprocess.run(["pactl", "list", "short", "sources"], capture_output=True, text=True, timeout=5)
    if not any(len(line.split()) > 1 and line.split()[1] == expected for line in sources.stdout.splitlines()):
        raise RuntimeError(L.t("linux.audioUnavailable"))
    return expected


def validate_mp4(path):
    result = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,width,height", "-of", "json", str(path)], capture_output=True, text=True, timeout=20)
    if result.returncode != 0:
        raise ValueError(L.t("engine.incomplete"))
    report = json.loads(result.stdout)
    video = next((stream for stream in report.get("streams", []) if stream.get("codec_type") == "video"), None)
    duration = float(report.get("format", {}).get("duration", 0))
    if not video or video.get("codec_name") != "h264" or duration <= 0 or video.get("width", 0) < 2 or video.get("height", 0) < 2:
        raise ValueError(L.t("engine.incomplete"))
    return duration, video["width"], video["height"]


class Recorder:
    def __init__(self):
        self.process = None
        self.stopping = False
        self.started_at = None
        self.timeout = None
        self._lock = threading.Lock()

    @property
    def active(self):
        return self.process is not None

    def start(self, directory, audio, rectangle=None, stream=None, on_started=None, on_completed=None, on_failed=None):
        if self.active:
            raise RuntimeError(L.t("engine.running"))
        if not shutil.which("ffprobe"):
            raise RuntimeError(L.t("linux.videoDependencies"))
        partial = Path(directory) / ("recording-" + uuid.uuid4().hex + ".partial.mp4")
        command = [sys.executable, str(Path(__file__).with_name("recorder_worker.py")), "--path", str(partial)]
        passed_fds = ()
        if stream:
            command += ["--pipewire-fd", str(stream["fd"]), "--node", str(stream["node"])]
            if stream.get("serial") is not None:
                command += ["--serial", str(stream["serial"])]
            passed_fds = (stream["fd"],)
        else:
            command += ["--display", os.environ.get("DISPLAY", ":0"), "--rectangle", *map(str, rectangle)]
        if audio:
            command += ["--audio-monitor", monitor_source()]
        self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, pass_fds=passed_fds, start_new_session=True)
        process = self.process
        self.stopping = False
        self.started_at = None
        self.timeout = None
        stderr_tail = []

        def read_errors():
            for line in process.stderr:
                stderr_tail.append(line)
                if len(stderr_tail) > 20:
                    stderr_tail.pop(0)
        error_reader = threading.Thread(target=read_errors, daemon=True)
        error_reader.start()

        def watch():
            messages = []
            try:
                for line in process.stdout:
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if message.get("event") == "started":
                        self.started_at = time.monotonic()
                        dispatch(on_started or (lambda: None))
                    if message.get("event") == "error":
                        messages.append(str(message.get("message", "")))
                process.wait()
                error_reader.join(timeout=2)
                detail = "".join(stderr_tail)[-1800:]
                if process.returncode != 0:
                    raise RuntimeError("\n".join(messages) or detail or L.t("record.failed"))
                duration, width, height = validate_mp4(partial)
                destination = partial.with_name(partial.name.replace(".partial.mp4", ".mp4"))
                if destination.exists():
                    raise FileExistsError(destination)
                os.rename(partial, destination)
                self.process = None
                self.stopping = False
                dispatch(on_completed, destination, duration, width, height)
            except Exception as error:
                self.process = None
                self.stopping = False
                message = str(error)
                if partial.exists():
                    message += "\n" + L.t("engine.partialFile", str(partial))
                dispatch(on_failed, message)
            finally:
                if self.timeout:
                    self.timeout.cancel()
                process.stdout.close()
                process.stderr.close()

        threading.Thread(target=watch, daemon=True).start()

    def stop(self):
        process = self.process
        if process is None or self.stopping:
            return
        self.stopping = True
        try:
            os.killpg(process.pid, signal.SIGINT)
        except ProcessLookupError:
            return

        def timeout():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
        self.timeout = threading.Timer(45, timeout)
        self.timeout.daemon = True
        self.timeout.start()
