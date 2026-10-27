# dmgbuild settings for the waveform dmg; run through tool/make_dmg.sh.
# icon positions and window size mirror DMG_* in tool/brand/make_icons.py.
import os.path

app = defines["app"]  # noqa: F821 — injected by dmgbuild
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_icon_preview = False
icon_size = 112
text_size = 12
arrange_by = None
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (170, 180),
    "Applications": (470, 180),
}
