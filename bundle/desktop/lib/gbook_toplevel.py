"""Window list helper (gbook-fit-active): talks to labwc through
wlr-foreign-toplevel-management (the same protocol the Xfce task list uses)."""
import os, struct, sys
sys.path.insert(0, "/usr/local/lib/gbook")
from pywayland.client import Display                                   # noqa: E402
from gproto.wayland import WlSeat                                      # noqa: E402
from gproto.wlr_foreign_toplevel_management_unstable_v1 import (      # noqa: E402
    ZwlrForeignToplevelManagerV1)

MAXIMIZED, MINIMIZED, ACTIVATED, FULLSCREEN = 0, 1, 2, 3


class Toplevel:
    def __init__(self, handle, order):
        self.handle, self.order = handle, order
        self.title, self.app_id, self.states, self.closed = "", "", set(), False

    @property
    def active(self):
        return ACTIVATED in self.states

    @property
    def minimized(self):
        return MINIMIZED in self.states


class Windows:
    def __init__(self):
        self.display = Display()
        self.display.connect()
        self.manager = self.seat = None
        self.toplevels = []
        reg = self.display.get_registry()
        reg.dispatcher["global"] = self._global
        self.display.roundtrip()          # globals
        if self.manager is None:
            raise RuntimeError("compositor has no wlr-foreign-toplevel-management")
        self.display.roundtrip()          # toplevel handles
        self.display.roundtrip()          # their title/app_id/state

    def _global(self, reg, name, interface, version):
        if interface == "zwlr_foreign_toplevel_manager_v1":
            self.manager = reg.bind(name, ZwlrForeignToplevelManagerV1, min(version, 3))
            self.manager.dispatcher["toplevel"] = self._new
        elif interface == "wl_seat" and self.seat is None:
            self.seat = reg.bind(name, WlSeat, min(version, 5))

    def _new(self, manager, handle):
        t = Toplevel(handle, len(self.toplevels))
        self.toplevels.append(t)
        d = handle.dispatcher
        d["title"] = lambda h, v: setattr(t, "title", v or "")
        d["app_id"] = lambda h, v: setattr(t, "app_id", v or "")

        def state(h, arr):
            raw = bytes(arr) if not isinstance(arr, (list, tuple)) else None
            vals = struct.unpack("=%dI" % (len(raw) // 4), raw) if raw is not None else arr
            t.states = set(vals)
        d["state"] = state
        d["closed"] = lambda h: setattr(t, "closed", True)

    def live(self):
        return [t for t in self.toplevels if not t.closed]

    def active(self):
        return next((t for t in self.live() if t.active), None)

    def activate(self, t):
        if t.minimized:
            t.handle.unset_minimized()
        t.handle.activate(self.seat)
        self.flush()

    def close(self, t):
        t.handle.close()
        self.flush()

    def minimize_all(self):
        for t in self.live():
            if not t.minimized:
                t.handle.set_minimized()
        self.flush()

    def flush(self):
        self.display.roundtrip()


def leave(code=0):
    """Exit without running the pywayland proxy finalizers: at interpreter
    shutdown they run after the display is gone and crash (SIGSEGV)."""
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)


def main():
    w = Windows()
    for t in w.live():
        print("%s\t%s\t%s\t%s" % (t.order, t.app_id, ",".join(map(str, sorted(t.states))), t.title))
    leave()


if __name__ == "__main__":
    main()
