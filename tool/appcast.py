#!/usr/bin/env python3
"""writes a sparkle/winsparkle appcast for one release asset and signs it.

the asset is signed with ed25519 (sparkle's `sign_update` format: base64 of the
signature over the raw file bytes). the private key comes from the env, never
from an argument:

  SPARKLE_ED_PRIVATE_KEY   base64 key as exported by sparkle 2.x
                           `generate_keys -x`: the 32-byte ed25519 seed
                           (sparkle's old 64-byte format is not supported)

  tool/appcast.py --platform macos --file waveform-macos-v0.4.0.dmg \
      --tag v0.4.0 --out appcast-macos.xml [--check-public-keys]

--check-public-keys (tag builds): the public key derived from the private one
must equal SUPublicEDKey in macos/Runner/Info.plist and EdDSAPub in
windows/runner/Runner.rc, otherwise installed apps could not verify the update.

needs `pip install cryptography`.
"""
import argparse
import base64
import os
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime
from xml.sax.saxutils import quoteattr

REPO = "mollykitten/waveform"
MACOS_MIN_OS = "12.0"


def read_pubspec_version(path="pubspec.yaml"):
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", line)
        if m:
            return m.group(1), m.group(2)
    sys.exit("pubspec.yaml: no `version: x.y.z+N` line")


def load_key():
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
    )

    raw = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "").strip()
    if not raw:
        sys.exit("SPARKLE_ED_PRIVATE_KEY is not set")
    seed = base64.b64decode(raw)
    if len(seed) != 32:
        sys.exit(
            f"unexpected key length: {len(seed)} bytes; expected the 32-byte "
            "seed from `generate_keys -x` (sparkle 2.x)"
        )
    return Ed25519PrivateKey.from_private_bytes(seed)


def public_key_b64(key):
    from cryptography.hazmat.primitives import serialization as ser

    raw = key.public_key().public_bytes(
        ser.Encoding.Raw, ser.PublicFormat.Raw
    )
    return base64.b64encode(raw).decode()


def sign_file(key, path):
    """signs the file and verifies the signature right away."""
    with open(path, "rb") as f:
        data = f.read()
    sig = key.sign(data)
    key.public_key().verify(sig, data)  # raises InvalidSignature
    return base64.b64encode(sig).decode()


def committed_public_keys():
    """the keys the shipped apps will trust: (macos plist, windows rc)."""
    plist = open("macos/Runner/Info.plist", encoding="utf-8").read()
    rc = open("windows/runner/Runner.rc", encoding="utf-8").read()
    m1 = re.search(r"<key>SUPublicEDKey</key>\s*<string>([^<]*)</string>", plist)
    m2 = re.search(r'EdDSAPub\s+EDDSA\s+\{"([^"]*)"\}', rc)
    if not m1 or not m2:
        sys.exit("could not find SUPublicEDKey / EdDSAPub in the sources")
    return m1.group(1).strip(), m2.group(1).strip()


def build_appcast(platform, tag, filename, length, signature, version, build):
    url = f"https://github.com/{REPO}/releases/download/{tag}/{filename}"
    if platform == "macos":
        # sparkle compares CFBundleVersion, which is the build number
        sparkle_version = build
        extra = f"      <sparkle:minimumSystemVersion>{MACOS_MIN_OS}" \
                "</sparkle:minimumSystemVersion>\n"
        os_attr = ""
    else:
        # winsparkle compares against the exe's ProductVersion string, which
        # is the whole pubspec version ("0.4.0+33"), so use it verbatim
        sparkle_version = f"{version}+{build}"
        extra = ""
        os_attr = (' sparkle:os="windows"'
                   ' sparkle:installerArguments="/SILENT /SP-"')
    pub = format_datetime(datetime.now(timezone.utc))
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Waveform</title>
    <link>https://github.com/{REPO}/releases</link>
    <item>
      <title>Waveform {version}</title>
      <link>https://github.com/{REPO}/releases/tag/{tag}</link>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{sparkle_version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
{extra}      <enclosure url={quoteattr(url)}{os_attr} length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=["macos", "windows"], required=True)
    ap.add_argument("--file", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--check-public-keys", action="store_true")
    a = ap.parse_args()

    version, build = read_pubspec_version()
    if a.tag.lstrip("v").split("-")[0] != version:
        sys.exit(f"tag {a.tag} does not match pubspec version {version}")
    key = load_key()
    if a.check_public_keys:
        derived = public_key_b64(key)
        mac, win = committed_public_keys()
        if derived != mac or derived != win:
            sys.exit(
                "the private key does not match the committed public key: "
                f"derived {derived}, Info.plist {mac}, Runner.rc {win}"
            )
    sig = sign_file(key, a.file)
    xml = build_appcast(
        a.platform, a.tag, os.path.basename(a.file),
        os.path.getsize(a.file), sig, version, build,
    )
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(xml)
    print(f"wrote {a.out}: {a.platform} {version} (build {build})")


if __name__ == "__main__":
    main()
