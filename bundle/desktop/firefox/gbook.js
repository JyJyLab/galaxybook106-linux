// /etc/firefox-esr/gbook.js — Galaxy Book 10.6 defaults for Firefox ESR
// System (labwc) title bar: labwc only accepts a window move started with the
// pointer, so with Firefox's own tab-strip title bar the window could not be
// moved by touch. With the system title bar touch drags work (2026-11-11).
pref("browser.tabs.inTitlebar", 0);
