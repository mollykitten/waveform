# design

dark by default, light theme later. 3 px radii, 0.5 px borders, orange only on what's active

| token | value | for |
|---|---|---|
| `bg` / `surface` / `surface2` | `#0A0A0A` / `#111111` / `#1A1A1A` | backgrounds |
| `textHi` / `textMid` / `textLow` | `#F5F5F5` / `#888888` / `#555555` | text |
| `acid` | `#FF5500` | active stuff only |
| `lime` | `#C6FF00` | secondary accent: markers and labels |

inter for text, jetbrains mono for every number, timecode and technical label. every number goes through `AppTheme.mono()`

## logo

the logo is five bars, the same shape as `lib/shared/widgets/wave_logo.dart`. in the app icon the first three are orange and the last two grey, like a track you're halfway through. svg logos live in [`assets/brand/`](../assets/brand/). the icon, favicons and the share card all come out of one script, so change the mark there and rerun it:

```bash
python3 tool/brand/make_icons.py
dart run flutter_launcher_icons
```

## landing page

plain static html in [`site/`](../site/), no build step. any static host works, point it at `site/`
