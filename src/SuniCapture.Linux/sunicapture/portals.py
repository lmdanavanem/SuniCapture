from __future__ import annotations

import os
import uuid

from .runtime import Gio, GLib, L

SERVICE = "org.freedesktop.portal.Desktop"
DESKTOP = "/org/freedesktop/portal/desktop"


class PortalClient:
    def __init__(self, connection=None):
        self.connection = connection or Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.requests = {}

    def request(self, interface, method, signature, arguments, options, callback):
        token = "sunicapture_" + uuid.uuid4().hex
        options = dict(options)
        options["handle_token"] = GLib.Variant("s", token)
        sender = self.connection.get_unique_name().lstrip(":").replace(".", "_")
        expected = "/org/freedesktop/portal/desktop/request/" + sender + "/" + token
        state = {"subscription": None, "timeout": None, "done": False}

        def complete(error, result=None):
            if state["done"]:
                return
            state["done"] = True
            if state["subscription"]:
                self.connection.signal_unsubscribe(state["subscription"])
            if state["timeout"]:
                GLib.source_remove(state["timeout"])
            self.requests.pop(expected, None)
            callback(error, result)

        def response(connection, sender_name, path, iface, signal, parameters, user_data):
            code, results = parameters.unpack()
            if code == 0:
                complete(None, results)
            else:
                complete(RuntimeError(L.t("status.cancelled") if code == 1 else L.t("linux.portalFailed")))

        def returned(connection, result, user_data):
            try:
                actual = connection.call_finish(result).unpack()[0]
                if actual != expected:
                    complete(RuntimeError(L.t("linux.portalFailed")))
            except GLib.Error as error:
                complete(error)

        def timed_out():
            state["timeout"] = None
            self.close_request(expected)
            complete(TimeoutError(L.t("linux.portalTimeout")))
            return False

        # Subscribe before the method call: fast portal responses must never be lost.
        state["subscription"] = self.connection.signal_subscribe(SERVICE, "org.freedesktop.portal.Request", "Response", expected, None, Gio.DBusSignalFlags.NONE, response, None)
        state["timeout"] = GLib.timeout_add_seconds(180, timed_out)
        self.requests[expected] = state
        parameters = GLib.Variant(signature, tuple(arguments) + (options,))
        self.connection.call(SERVICE, DESKTOP, interface, method, parameters, GLib.VariantType.new("(o)"), Gio.DBusCallFlags.NONE, 15000, None, returned, None)
        return expected

    def property(self, interface, name, default=None):
        try:
            result = self.connection.call_sync(SERVICE, DESKTOP, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", (interface, name)), GLib.VariantType.new("(v)"), Gio.DBusCallFlags.NONE, 3000, None)
            value = result.unpack()[0]
            return value.unpack() if isinstance(value, GLib.Variant) else value
        except GLib.Error:
            return default

    def screenshot(self, mode, callback):
        interface = "org.freedesktop.portal.Screenshot"
        options = {"interactive": GLib.Variant("b", True), "modal": GLib.Variant("b", True)}
        targets = self.property(interface, "AvailableTargets", 0)
        target = {"screen": 1, "window": 2, "region": 4}.get(mode, 1)
        if targets & target:
            options["target"] = GLib.Variant("u", target)

        def completed(error, results):
            if error:
                callback(error, None)
                return
            uri = results.get("uri", "")
            file = Gio.File.new_for_uri(uri)
            path = file.get_path()
            if not path or not uri.startswith("file:"):
                callback(ValueError(L.t("linux.portalFailed")), None)
                return
            callback(None, path)
        return self.request(interface, "Screenshot", "(sa{sv})", ("",), options, completed)

    def screencast(self, callback):
        interface = "org.freedesktop.portal.ScreenCast"
        session = {"path": None, "closed": False}

        def failed(error):
            if session["path"]:
                self.close_session(session["path"])
            callback(error, None)

        def created(error, results):
            if error:
                failed(error)
                return
            session["path"] = results.get("session_handle")
            if not session["path"]:
                failed(ValueError(L.t("linux.portalFailed")))
                return
            source_types = self.property(interface, "AvailableSourceTypes", 1) & 3
            cursor_modes = self.property(interface, "AvailableCursorModes", 1)
            options = {"types": GLib.Variant("u", source_types or 1), "multiple": GLib.Variant("b", False),
                       "cursor_mode": GLib.Variant("u", 2 if cursor_modes & 2 else 1)}
            self.request(interface, "SelectSources", "(oa{sv})", (session["path"],), options, selected)

        def selected(error, results):
            if error:
                failed(error)
                return
            self.request(interface, "Start", "(osa{sv})", (session["path"], ""), {}, started)

        def started(error, results):
            if error:
                failed(error)
                return
            streams = results.get("streams", [])
            if len(streams) != 1:
                failed(ValueError(L.t("linux.portalFailed")))
                return
            try:
                response, descriptors = self.connection.call_with_unix_fd_list_sync(SERVICE, DESKTOP, interface, "OpenPipeWireRemote",
                    GLib.Variant("(oa{sv})", (session["path"], {})), GLib.VariantType.new("(h)"), Gio.DBusCallFlags.NONE, 10000, None, None)
                descriptor = descriptors.get(response.unpack()[0])
                node, properties = streams[0]
                callback(None, dict(fd=descriptor, node=node, serial=properties.get("pipewire-serial"), session=session["path"]))
            except (GLib.Error, OSError) as error:
                failed(error)

        return self.request(interface, "CreateSession", "(a{sv})", (), {"session_handle_token": GLib.Variant("s", "sunicapture_" + uuid.uuid4().hex)}, created)

    def close_request(self, path):
        self.connection.call(SERVICE, path, "org.freedesktop.portal.Request", "Close", None, None, Gio.DBusCallFlags.NONE, 3000, None, None, None)

    def close_session(self, path):
        self.connection.call(SERVICE, path, "org.freedesktop.portal.Session", "Close", None, None, Gio.DBusCallFlags.NONE, 3000, None, None, None)
