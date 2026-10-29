"""Exercise portal requests on a private bus, without touching desktop permissions."""
from pathlib import Path
import os
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/SuniCapture.Linux"))
from sunicapture.runtime import Gio, GLib
from sunicapture.portals import PortalClient, SERVICE, DESKTOP


XML = """<node>
<interface name="org.freedesktop.portal.Screenshot">
 <method name="Screenshot"><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
 <property name="AvailableTargets" type="u" access="read"/>
</interface>
<interface name="org.freedesktop.portal.ScreenCast">
 <method name="CreateSession"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
 <method name="SelectSources"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
 <method name="Start"><arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
 <method name="OpenPipeWireRemote"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="h" direction="out"/></method>
 <property name="AvailableSourceTypes" type="u" access="read"/>
 <property name="AvailableCursorModes" type="u" access="read"/>
</interface>
<interface name="org.freedesktop.portal.Session"><method name="Close"/></interface>
</node>"""


class TestPortal:
    def __init__(self, address):
        self.address = address
        self.context = GLib.MainContext.new()
        self.ready = threading.Event()
        self.calls = []
        self.closed = []
        self.targets = 7
        self.cancel = None
        self.uri = "file:///tmp/sunicapture-portal-fixture.png"
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        if not self.ready.wait(5):
            raise RuntimeError("Private portal did not start.")

    def serve(self):
        self.context.push_thread_default()
        flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
        self.connection = Gio.DBusConnection.new_for_address_sync(self.address, flags, None, None)
        self.connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
            GLib.Variant("(su)", (SERVICE, 0)), None, Gio.DBusCallFlags.NONE, 3000, None)
        node = Gio.DBusNodeInfo.new_for_xml(XML)
        for interface in node.interfaces[:2]:
            self.connection.register_object(DESKTOP, interface, self.method, self.property, None)
        self.session = "/org/freedesktop/portal/desktop/session/test/session1"
        self.connection.register_object(self.session, node.interfaces[2], self.method, None, None)
        self.loop = GLib.MainLoop.new(self.context, False)
        self.ready.set()
        self.loop.run()
        self.connection.close_sync(None)
        self.context.pop_thread_default()

    def property(self, connection, sender, path, interface, name):
        return GLib.Variant("u", {"AvailableTargets": self.targets, "AvailableSourceTypes": 3, "AvailableCursorModes": 3}[name])

    def method(self, connection, sender, path, interface, method, parameters, invocation):
        args = parameters.unpack()
        self.calls.append((method, args))
        if method == "Close":
            self.closed.append(path)
            invocation.return_value(GLib.Variant("()", ()))
            return
        if method == "OpenPipeWireRemote":
            fd = os.open("/dev/null", os.O_RDONLY)
            try:
                descriptors = Gio.UnixFDList.new()
                index = descriptors.append(fd)
                invocation.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), descriptors)
            finally:
                os.close(fd)
            return
        options = args[-1]
        token = options["handle_token"]
        request = DESKTOP + "/request/" + sender.lstrip(":").replace(".", "_") + "/" + token
        code = 1 if self.cancel == method else 0
        result = {}
        if method == "Screenshot":
            result = {"uri": GLib.Variant("s", self.uri)}
        elif method == "CreateSession":
            result = {"session_handle": GLib.Variant("o", self.session)}
        elif method == "Start":
            result = {"streams": GLib.Variant("a(ua{sv})", [(43, {"pipewire-serial": GLib.Variant("t", 123456), "size": GLib.Variant("(ii)", (1600, 900))})])}
        # Intentionally emit before returning the method handle.
        connection.emit_signal(sender, request, "org.freedesktop.portal.Request", "Response", GLib.Variant("(ua{sv})", (code, result)))
        invocation.return_value(GLib.Variant("(o)", (request,)))

    def stop(self):
        self.loop.quit()
        self.thread.join(timeout=3)


def spin(condition):
    deadline = time.monotonic() + 8
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        if condition():
            return
        time.sleep(.01)
    raise TimeoutError("Private portal response timed out.")


def main():
    bus = Gio.TestDBus.new(Gio.TestDBusFlags.NONE)
    bus.up()
    server = TestPortal(bus.get_bus_address())
    flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
    connection = Gio.DBusConnection.new_for_address_sync(bus.get_bus_address(), flags, None, None)
    portal = PortalClient(connection)
    checks = []
    def require(value, message):
        if not value:
            raise AssertionError(message)
        checks.append(message)
        print("PASS: " + message)
    def request(action):
        result = []
        action(lambda error, value: result.append((error, value)))
        spin(lambda: result)
        return result[0]
    try:
        error, path = request(lambda callback: portal.screenshot("region", callback))
        require(not error and path == "/tmp/sunicapture-portal-fixture.png", "Fast portal screenshot responses are received on the private bus")
        options = server.calls[-1][1][-1]
        require(options["interactive"] and options["target"] == 4, "Region capture requests the advertised screenshot target with a permission dialog")
        server.targets = 0
        error, path = request(lambda callback: portal.screenshot("window", callback))
        require(not error and "target" not in server.calls[-1][1][-1], "Older screenshot portals fall back to the system selector")
        server.cancel = "Screenshot"
        error, path = request(lambda callback: portal.screenshot("screen", callback))
        require(error and path is None and not portal.requests, "Cancelling screenshot permission completes once and cleans request subscriptions")
        server.cancel = None
        server.uri = "https://example.invalid/capture.png"
        error, path = request(lambda callback: portal.screenshot("screen", callback))
        require(isinstance(error, ValueError) and path is None, "Screenshot portal rejects a nonlocal image URI")
        error, stream = request(portal.screencast)
        require(not error and stream["node"] == 43 and stream["serial"] == 123456 and os.fstat(stream["fd"]), "ScreenCast receives a real passed descriptor and stream identity")
        methods = [name for name, _ in server.calls]
        require(methods[-4:] == ["CreateSession", "SelectSources", "Start", "OpenPipeWireRemote"], "ScreenCast follows session, source selection, permission and remote-open order")
        options = next(args[-1] for name, args in reversed(server.calls) if name == "SelectSources")
        require(options["types"] == 3 and not options["multiple"] and options["cursor_mode"] == 2, "ScreenCast requests one supported source with the cursor embedded")
        os.close(stream["fd"])
        portal.close_session(stream["session"])
        spin(lambda: server.closed)
        require(server.closed[-1] == stream["session"], "Finishing ScreenCast closes its own portal session")
        server.cancel = "SelectSources"
        before = len(server.closed)
        error, stream = request(portal.screencast)
        spin(lambda: len(server.closed) > before)
        require(error and stream is None and not portal.requests, "Cancelling ScreenCast selection closes the unused session")
        print("PASS: " + str(len(checks)) + " portal contract checks; physical compositor capture is not exercised.")
    finally:
        connection.close_sync(None)
        server.stop()
        bus.down()


if __name__ == "__main__":
    main()
