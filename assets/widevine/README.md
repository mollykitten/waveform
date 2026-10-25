# Widevine-профиль устройства (GO+)

Положить сюда `device.wvd` — профиль Widevine-устройства, которым плеер
представляется лиценз-серверу SoundCloud (`license.media-streaming.soundcloud.cloud`).

- Как получить: см. `third_party/scdrm/wvdumper/` (README + WVD_DUMP_GUIDE) —
  дамп из Chromium-профиля с пройденным CDM-дрейпом.
- Файл **не коммитим**: это привязка к «устройству», его раздают.
- Без `device.wvd` GO+-треки остаются непроигрываемыми — приложение
  логгирует `scdrm: нет ассета assets/widevine/device.wvd` и живёт как раньше.
