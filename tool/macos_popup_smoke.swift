// Native, account-free test of the actual vendored PopupWindowController.
// Run from the repo root:
// swiftc -parse-as-library third_party/desktop_webview_window/macos/desktop_webview_window/Sources/desktop_webview_window/PopupWindowController.swift tool/macos_popup_smoke.swift -o build/macos_popup_smoke
// build/macos_popup_smoke
// This does NOT prove Google login or the Flutter parent/hidden-sync integration.
import Cocoa
import WebKit

private func wait(_ condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
  let end = Date().addingTimeInterval(timeout)
  while !condition() && Date() < end {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
  return condition()
}

private func snapshot(_ label: String, _ window: NSWindow) {
  guard let flag = CommandLine.arguments.firstIndex(of: "--screenshots"),
        CommandLine.arguments.indices.contains(flag + 1) else { return }
  let path = CommandLine.arguments[flag + 1] + "/" + label + ".png"
  guard let view = window.contentView as? WKWebView else { return }
  var done = false
  var image: NSImage?
  view.takeSnapshot(with: nil) { result, error in
    image = result
    if let error = error { print("Snapshot error: \(error)") }
    done = true
  }
  precondition(wait({ done }), "Snapshot timed out")
  guard let tiff = image?.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:]) else {
    preconditionFailure("Snapshot failed")
  }
  do {
    try png.write(to: URL(fileURLWithPath: path))
    print("WEB_CONTENT_SNAPSHOT \(path)")
  } catch { preconditionFailure("Snapshot failed: \(error)") }
}

private func evaluate(_ view: WKWebView, _ script: String) -> Any? {
  var done = false
  var value: Any?
  view.evaluateJavaScript(script) { result, error in
    value = result
    if let error = error { print("JS error: \(error.localizedDescription)") }
    done = true
  }
  precondition(wait({ done }), "JavaScript timed out")
  return value
}

// Adapter only: reproduces upstream routing, or hands WebKit's supplied
// configuration to the actual production PopupWindowController.
private final class Parent: NSObject, WKUIDelegate {
  let window: NSWindow
  let view: WKWebView
  var popups: [PopupWindowController] = []
  var closed = 0
  let upstream: Bool

  init(upstream: Bool = false) {
    self.upstream = upstream
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration)
    window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.title = "Waveform native popup test (no account)"
    super.init()
    view.uiDelegate = self
    window.orderFront(nil)
    view.loadHTMLString("<html><title>parent</title><body>Local popup test</body></html>", baseURL: URL(string: "https://waveform-popup.invalid/"))
    precondition(wait({ !self.view.isLoading }))
    _ = evaluate(view, "window.received=[];addEventListener('message',e=>received.push(e.data));true")
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if upstream {
      webView.load(action.request)
      return nil
    }
    let popup = PopupWindowController(configuration: configuration, windowFeatures: windowFeatures, parent: window, userAgent: nil) { [weak self] closed in
      self?.closed += 1
      self?.popups.removeAll { $0 === closed }
    }
    popups.append(popup)
    popup.showWindow(nil)
    return popup.webView
  }

  func cleanup() {
    let open = popups
    popups.removeAll()
    open.forEach { $0.close() }
    view.stopLoading()
    view.uiDelegate = nil
    window.close()
  }
}

@main
private struct Smoke {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    var failures = 0
    func check(_ name: String, _ success: Bool) {
      print("\(success ? "PASS" : "FAIL") \(name)")
      if !success { failures += 1 }
    }

    let baseline = Parent(upstream: true)
    check("upstream window.open returns null (no child/opener)", evaluate(baseline.view, "window.open('about:blank','baseline') === null") as? Bool == true)
    snapshot("before-upstream-no-child", baseline.window)
    baseline.cleanup()

    let parent = Parent()
    check("patched window.open returns a child", evaluate(parent.view, "window.child=window.open('about:blank','child');child!==null") as? Bool == true)
    check("separate native child created", parent.popups.count == 1)
    guard let child = parent.popups.first else { exit(1) }
    check("child has live opener", evaluate(child.webView, "window.opener!==null") as? Bool == true)
    _ = evaluate(child.webView, "window.opener.postMessage('reply','*');document.cookie='popup_smoke=shared;path=/';true")
    check("postMessage reaches parent", wait({ evaluate(parent.view, "received.includes('reply')") as? Bool == true }))
    var shared = false
    var cookiesDone = false
    parent.view.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
      shared = cookies.contains { $0.name == "popup_smoke" && $0.value == "shared" }
      cookiesDone = true
    }
    check("child cookie reaches parent native store", wait({ cookiesDone }) && shared)
    check("parent document not replaced", evaluate(parent.view, "document.title") as? String == "parent")
    _ = evaluate(child.webView, "document.body.innerHTML='<h1>Separate native child</h1><p>opener + postMessage + shared cookie: PASS</p>';document.title='Local popup — no credentials';true")
    snapshot("after-real-child", child.window!)
    snapshot("after-parent-preserved", parent.window)

    check("nested window.open preserves a real child", evaluate(child.webView, "window.grandchild=window.open('about:blank','nested');grandchild!==null") as? Bool == true)
    let descendants = app.windows.filter { $0.isVisible && $0 !== parent.window && $0 !== child.window }
    check("nested popup has its own native window", descendants.count == 1)
    _ = evaluate(child.webView, "window.close();true")
    check("window.close removes child controller", wait({ parent.closed == 1 && parent.popups.isEmpty }))
    check("closing child closes its descendants", descendants.count == 1 && descendants.allSatisfy { !$0.isVisible })

    _ = evaluate(parent.view, "window.child2=window.open('about:blank','child2');true")
    if let second = parent.popups.first {
      second.window?.performClose(nil)
      check("native close removes child controller", wait({ parent.closed == 2 && parent.popups.isEmpty }))
    } else {
      check("second popup created", false)
    }
    print("Native popup controller failures: \(failures)")
    exit(failures == 0 ? 0 : 1)
  }
}
