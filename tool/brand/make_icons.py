"""Генератор бренд-ассетов Waveform: иконка приложения, фавиконки, OG-картинка.

Запуск из корня репо:  python3 tool/brand/make_icons.py
Потом:                 dart run flutter_launcher_icons

Геометрия марки повторяет lib/shared/widgets/wave_logo.dart: 5 баров,
ширина бара = зазор = size/9, высоты [0.5, 1.0, 0.35, 0.8, 0.6],
центрированы по вертикали. В иконке первые три бара — acid (прослушано),
последние два — waveDim (не прослушано), как активный waveform в плеере.
"""

import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]

BG = (10, 10, 10)
SURFACE_TOP = (28, 28, 28)
ACID = (255, 85, 0)
WAVE_DIM = (58, 58, 58)
TEXT_HI = (245, 245, 245)
TEXT_MID = (136, 136, 136)

HEIGHTS = [0.5, 1.0, 0.35, 0.8, 0.6]
SS = 4  # суперсэмплинг для гладких краёв


def superellipse(box, n=5.0, steps=720):
    import math

    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    a, b = (x1 - x0) / 2, (y1 - y0) / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + a * (abs(c) ** (2 / n)) * (1 if c >= 0 else -1)
        y = cy + b * (abs(s) ** (2 / n)) * (1 if s >= 0 else -1)
        pts.append((x, y))
    return pts


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    for y in range(h):
        k = y / (h - 1)
        grad.putpixel(
            (0, y), tuple(round(top[i] + (bottom[i] - top[i]) * k) for i in range(3))
        )
    return grad.resize((w, h))


def draw_mark(draw, box, colors, radius_k=0.2):
    """Пять баров в квадрате box=(x, y, size)."""
    x, y, size = box
    bar = size / 9
    for i, h in enumerate(HEIGHTS):
        bx = x + i * 2 * bar
        bh = size * h
        by = y + (size - bh) / 2
        draw.rounded_rectangle(
            (bx, by, bx + bar, by + bh), radius=bar * radius_k, fill=colors[i]
        )


def app_icon(variant="played", px=1024):
    """macOS-иконка: squircle 824/1024 с полями и тенью (Apple grid)."""
    s = px * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    inset = round(s * 100 / 1024)
    box = (inset, inset, s - inset, s - inset)
    shape = superellipse(box)

    # Тень под плиткой.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    off = round(s * 10 / 1024)
    sd.polygon([(x, y + off) for x, y in shape], fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(s * 14 / 1024))
    img.alpha_composite(shadow)

    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).polygon(shape, fill=255)

    if variant == "acid":
        tile = vertical_gradient((s, s), (255, 110, 30), (240, 72, 0)).convert("RGBA")
    else:
        tile = vertical_gradient((s, s), SURFACE_TOP, BG).convert("RGBA")
        # Тёплое свечение под прослушанной частью — тихо, без «градиентной каши».
        glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        r = s * 0.26
        cx, cy = s * 0.42, s * 0.52
        gd.ellipse((cx - r, cy - r, cx + r, cy + r), fill=ACID + (46,))
        glow = glow.filter(ImageFilter.GaussianBlur(s * 0.12))
        tile.alpha_composite(glow)

    d = ImageDraw.Draw(tile)
    mark = s * 0.45
    mx, my = (s - mark) / 2, (s - mark) / 2
    if variant == "played":
        colors = [ACID, ACID, ACID, WAVE_DIM, WAVE_DIM]
    elif variant == "acid":
        colors = [BG] * 5
    else:
        colors = [ACID] * 5
    draw_mark(d, (mx, my, mark), colors)

    clipped = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    clipped.paste(tile, (0, 0), mask)
    img.alpha_composite(clipped)

    # Волосяной кант сверху: 0.5px-бордеры из дизайн-контракта, масштабированные.
    rim = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(rim).line(
        shape + [shape[0]], fill=(255, 255, 255, 26), width=round(s * 3 / 1024)
    )
    rim_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(rim_mask).polygon(shape, fill=255)
    fade = vertical_gradient((s, s), (255,) * 3, (40,) * 3).convert("L")
    rim.putalpha(Image.composite(rim.getchannel("A"), Image.new("L", (s, s)), fade))
    img.alpha_composite(rim)

    return img.resize((px, px), Image.LANCZOS)


def full_bleed(px, transparent=False):
    """Квадрат без полей: apple-touch-icon, фавиконка."""
    s = px * SS
    bg = (0, 0, 0, 0) if transparent else BG + (255,)
    img = Image.new("RGBA", (s, s), bg)
    d = ImageDraw.Draw(img)
    if not transparent:
        d.rounded_rectangle((0, 0, s, s), radius=0, fill=BG)
    mark = s * (0.86 if transparent else 0.56)
    draw_mark(
        d,
        ((s - mark) / 2, (s - mark) / 2, mark),
        [ACID, ACID, ACID, WAVE_DIM, WAVE_DIM] if not transparent else [ACID] * 5,
    )
    return img.resize((px, px), Image.LANCZOS)


FONT_DIRS = [
    Path.home() / "Library/Fonts",
    Path("/Library/Fonts"),
    Path.home() / ".local/share/fonts",
    Path.home() / ".fonts",
    Path("/usr/share/fonts"),
    Path("/usr/local/share/fonts"),
    Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft/Windows/Fonts",
    Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts",
]


def find_mono_fonts():
    """JetBrains Mono для OG-картинки: (bold, regular) пути.

    Ищет переменный `JetBrainsMono[wght].ttf` или статические
    `JetBrainsMono-Bold/-Regular.ttf` в системных папках шрифтов
    macOS / Linux / Windows. `WAVEFORM_MONO_FONT` указывает файл явно.
    Падает до записи любых ассетов, если шрифта нет.
    """
    explicit = os.environ.get("WAVEFORM_MONO_FONT")
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            sys.exit(f"WAVEFORM_MONO_FONT={explicit} не найден")
        return path, path
    for base in FONT_DIRS:
        if not base.is_dir():
            continue
        variable = sorted(base.rglob("JetBrainsMono[[]wght[]].ttf"))
        if variable:
            return variable[0], variable[0]
        bold = sorted(base.rglob("JetBrainsMono-Bold.ttf"))
        regular = sorted(base.rglob("JetBrainsMono-Regular.ttf"))
        if bold and regular:
            return bold[0], regular[0]
    sys.exit(
        "JetBrains Mono не найден. Поставь шрифт "
        "(https://www.jetbrains.com/lp/mono/) или укажи файл "
        "через WAVEFORM_MONO_FONT=/path/to/JetBrainsMono.ttf"
    )


def load_font(path, size, weight):
    font = ImageFont.truetype(str(path), size)
    try:
        font.set_variation_by_name(weight)
    except (OSError, ValueError):
        pass  # статический файл: вес уже зашит в нём
    return font


def og_image(fonts):
    w, h = 1200, 630
    s = SS
    img = Image.new("RGBA", (w * s, h * s), BG + (255,))
    d = ImageDraw.Draw(img)
    bold_path, regular_path = fonts
    big = load_font(bold_path, 96 * s, "Bold")
    small = load_font(regular_path, 30 * s, "Regular")

    # Waveform-полоса снизу: прослушано / не прослушано.
    import math

    bars, gap, bw = 104, 4 * s, 6 * s
    base = 470 * s
    x = 80 * s
    for i in range(bars):
        t = i / bars
        amp = (0.35 + 0.65 * abs(math.sin(i * 0.37) * math.cos(i * 0.11))) * 90 * s
        col = ACID if t < 0.42 else WAVE_DIM
        d.rectangle((x, base - amp, x + bw, base), fill=col)
        d.rectangle((x, base + 6 * s, x + bw, base + 6 * s + amp * 0.4), fill=col + (90,))
        x += bw + gap

    draw_mark(d, (80 * s, 110 * s, 96 * s), [ACID] * 5)
    d.text((200 * s, 100 * s), "waveform", font=big, fill=TEXT_HI)
    d.text(
        (82 * s, 250 * s),
        "a keyboard-first soundcloud client for desktop",
        font=small,
        fill=TEXT_MID,
    )
    return img.resize((w, h), Image.LANCZOS).convert("RGB")


def main():
    brand = ROOT / "assets/brand"
    site = ROOT / "site/assets"

    # Сначала рендерим всё в память: если чего-то не хватает (шрифта),
    # скрипт падает, не оставив половину ассетов перезаписанной.
    fonts = find_mono_fonts()
    icon = app_icon("played")
    outputs = {
        ROOT / "assets/icon/icon.png": icon,
        brand / "icon-1024.png": icon,
        brand / "icon-256.png": icon.resize((256, 256), Image.LANCZOS),
        brand / "icon-alt-solid-1024.png": app_icon("solid"),
        brand / "icon-alt-acid-1024.png": app_icon("acid"),
        site / "icon-512.png": icon.resize((512, 512), Image.LANCZOS),
        site / "apple-touch-icon.png": full_bleed(180).convert("RGB"),
        site / "favicon-32.png": full_bleed(32, transparent=True),
        site / "og.png": og_image(fonts),
    }

    for path, image in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        image.save(path, optimize=path.name == "og.png")
    print("ok")


if __name__ == "__main__":
    main()
