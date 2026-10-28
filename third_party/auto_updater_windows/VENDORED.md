# vendored auto_updater_windows

copy of `auto_updater_windows` 1.0.0 (leanflutter/auto_updater, MIT) with the
bundled winsparkle bumped from 0.8.1 to **0.9.4**. 0.8.1 only knows dsa
signatures and accepts unsigned updates when no dsa key is configured; 0.9.x
verifies ed25519 (`sparkle:edSignature`) with the key from the `EdDSAPub`
resource in `windows/runner/Runner.rc`.

changes against the pub.dev release:
- `windows/WinSparkle-0.8.1/` replaced by `windows/WinSparkle-0.9.4/`
  (headers, `x64/Release/WinSparkle.dll` and `.lib`, licenses; no pdb, no
  win32/arm64 builds: flutter windows builds here are x64 only)
- `windows/CMakeLists.txt` and `windows/auto_updater.cpp` point at the new dir
- the plugin's `test/` is dropped

winsparkle binaries come only from the official release
https://github.com/vslavik/winsparkle/releases/tag/v0.9.4
(`WinSparkle-0.9.4.zip`, published 2026-07-21).

| file | sha256 |
| --- | --- |
| `WinSparkle-0.9.4.zip` (release asset) | `6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976` |
| `x64/Release/WinSparkle.dll` | `9b43b1c16ee39fb9a91b5bd75138767898779510e0836be2919250607cdbe8ab` |
| `x64/Release/WinSparkle.lib` | `55cedd7152df575d6c521661908b52a6d188c89d9967d69560d7106ddbf5715b` |
| `include/winsparkle.h` | `68bc74f82300361af00a5080b254c7e2f3a3af7ad6e98546751f9e090b9c1d22` |

the zip hash equals the digest github shows for the asset. to check the
vendored files: unzip the release and compare with `shasum -a 256`.

## signature enforcement

in winsparkle 0.9.4 `src/updatedownloader.cpp`, when an ed25519 public key is
set the downloaded installer goes through
`SignatureVerifier::VerifyEdDSASignatureValid`, which throws
`BadSignatureException` on a missing or wrong signature, and the update is
rejected. only when **no** valid key is configured does it fall back to
accepting unsigned updates, so a placeholder `EdDSAPub` must never ship
(release.yml refuses tag builds with it). this was read from the source, not
exercised on a windows machine.
