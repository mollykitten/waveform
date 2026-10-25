# Desktop popup / Google sign-in verification (PR #22)

**Status: BLOCKED, not ready for review or merge as Google sign-in support.**

## Boundary: a working popup is not a supported Google login

Google's [OAuth policy, “Use secure browsers”](https://developers.google.com/identity/protocols/oauth2/policies#browsers)
explicitly prohibits directing Google OAuth authorization requests to an embedded
user-agent controlled by the developer. It specifically includes libraries that
can inject scripts, reroute requests or access cookies — capabilities of this
application's WebView. A separate WKWebView window does not change that boundary.

The original PR appended `Version/18.0 Safari/605.1.15` to impersonate Safari.
That suffix has been removed. Do not reintroduce UA spoofing, anti-bot bypasses,
provider security-check workarounds or browser-cookie extraction. No real Google
account was opened or authenticated during automated verification. A policy
blocker must not be turned into a “passed login” claim by a successful local test.

### Documented allowed direction, not implemented by this PR

Use a real external browser and SoundCloud's registered-application OAuth 2.1
Authorization Code + PKCE flow, rather than attempting Google OAuth inside this
app. [SoundCloud's current guide](https://developers.soundcloud.com/docs/api/guide#authentication)
documents `secure.soundcloud.com/authorize`, PKCE S256, state, a registered redirect
URI, token exchange and refresh. Its current prerequisites describe application
registration through an Artist Pro account / Your Apps; the older repository
note that registration is closed must not be assumed current.

This requires a Waveform-owned registered app, an approved redirect and a decision
on secure token exchange (the guide includes a client secret and server-side
implementation). Do not embed a confidential client secret in a desktop binary,
reuse SoundCloud's first-party OAuth client, invent a redirect or assume these
API tokens can replace the existing api-v2 session without live validation.
Credentials / account setup and that integration are not present in this PR.
Opening SoundCloud in Safari alone cannot securely copy the session back into the
app and is not an implemented solution. Any account-bearing supported-flow check
must be performed by the user, with passwords/2FA kept out of tools, chat and logs.

## Reproduction and implementation

- Upstream macOS `createWebViewWith` loads the popup URL into its parent and returns
  nil. An account-free native reproduction observes `window.open(...) === null`:
  no child/opener, with the parent's page replaced.
- The existing PR creates a separate WKWebView with WebKit's supplied configuration,
  preserving opener, `postMessage` and the application's own cookie store.
- An additional regression in the initial PR is reproduced by a nested
  `window.open`: its popup controller repeated the same same-window fallback.
  The native regression run against the original controller reports **3 failures**
  (nested child, native nested window, cascading cleanup). The controller now owns
  nested popup controllers and closes descendants when closed.
- Parent destruction closes root popups; hidden sync retains upstream same-view
  navigation and does not enter the visible-popup branch. The login polling /
  validation logic is otherwise unchanged.

## Reproducible checks

### macOS native controller, no Flutter / accounts

From the repository root:

```sh
mkdir -p build/popup-evidence
swiftc -parse-as-library \
  third_party/desktop_webview_window/macos/desktop_webview_window/Sources/desktop_webview_window/PopupWindowController.swift \
  tool/macos_popup_smoke.swift -o build/macos_popup_smoke
build/macos_popup_smoke --screenshots build/popup-evidence
```

Observed: **Native popup controller failures: 0**. Verifies separate child,
opener, postMessage, shared native cookie store, intact parent, nested child,
JavaScript close, native close and descendant cleanup. The optional PNGs use
WKWebView snapshots: they show **web content only, not native window chrome**.
The blank baseline is the replaced parent after upstream loads `about:blank`.
The after page is a clearly labelled local test, not SoundCloud / Google UI.
Screenshots alone do not establish the login result; assertions establish the
local popup behaviour.

### Actual Flutter parent / hidden-sync integration, loopback only

Dart MCP `launch_app` with this project root, `device: macos`, and
`target: tool/webview_popup_smoke.dart`. Check `get_app_logs` for
`POPUP_SMOKE_RESULT PASS`, then `stop_app` for that exact launch PID.
A failed assertion prints `POPUP_SMOKE_RESULT FAIL`; this interactive probe does
not turn a failure into a reliable shell exit status and is not a CI test.

Observed with the actual vendored plugin: child/opener, postMessage, shared native
cookie store, child.close, parent.onClose, hidden sync same-view navigation all
PASS. Native window enumeration after cleanup found only this process's main
window (no abandoned popup). The loopback server and test windows are closed by
`finally`; a test-only localhost cookie is expired after its assertion. The probe
never navigates to an account service or prints a session cookie. It does not
continuously observe screen visibility during the hidden-window test.

The first MCP launch timed out during native compilation; the orphan build
finished, no app survived, and a subsequent incremental MCP launch succeeded.
There were existing `Communicating on a dead channel` messages during secondary
Flutter-engine teardown; no probe assertion failed. No global tool or signing
settings were changed to make the probe pass.

### App / quality gates

- Flutter 3.41.0 / Dart 3.11.0.
- Dart MCP analyze: no errors.
- Full Dart MCP test suite: passed (see task evidence for exact-head count).
- Real `flutter build macos --debug --no-tree-shake-icons`, with
  `FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO`,
  `FLUTTER_XCODE_CODE_SIGNING_REQUIRED=NO`,
  `FLUTTER_XCODE_DEVELOPMENT_TEAM=''`: built Waveform.app successfully.
  Local Xcode linker warnings about a missing MetalToolchain search path remain;
  this is not a signed, notarized or release build.

## Platform acceptance / outstanding gates

| Area | Evidence | Status |
|---|---|---|
| macOS native compile | Real app build + native Swift probe | PASS |
| macOS local popup lifecycle | Native controller + actual Flutter loopback probe | PASS, local pages only |
| Hidden sync | Actual plugin same-view navigation; no leftovers after cleanup | PASS for local behaviour, not continuous visual observation |
| Windows build / lifecycle | No Windows host execution | NOT VERIFIED |
| Linux build / lifecycle | No Linux host execution | NOT VERIFIED |
| Google / SoundCloud account login | No user account-bearing test | NOT VERIFIED; embedded flow additionally policy-blocked |
| Supported external-browser OAuth | Provider documentation only | NOT IMPLEMENTED; registration / token-exchange decision needed |

Existing CI workflows are analyze/test, macOS debug build, and a tag-triggered
release workflow. There is **no existing non-release Windows/Linux build job** to
run for this PR; release has deliberately not been triggered, and CI was not
changed as a side effect. Windows' default WebView2 popup path and Linux's related
WebKit view have not been proven by macOS compilation. In particular, do not
assume default Windows popup parent ownership, Linux nested popup handling or
cross-platform hidden behaviour from the macOS result. Run the local loopback
scenario and native builds on those actual platforms before claiming acceptance.

Required next decision: retain this as generic popup infrastructure and separately
implement the registered external-browser flow, or provide access / scope for a
supported auth integration. A user-confirmed login does not waive Google's policy.
Do not approve / merge this PR as “Google login fixed” while these gates remain.
