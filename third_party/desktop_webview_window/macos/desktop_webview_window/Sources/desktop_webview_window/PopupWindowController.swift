//
//  PopupWindowController.swift
//  desktop_webview_window
//
//  waveform patch: настоящее окно для попапа, который страница открывает через
//  window.open() — OAuth «Continue with Google / Apple / Facebook» на странице
//  входа SoundCloud. Upstream грузил URL попапа в то же webview: у страницы
//  провайдера не было `window.opener`, результат входа некуда было вернуть
//  (postMessage в пустоту), и вход зависал на «popup blocked» / белом экране.
//
//  WKWebView попапа создаётся с тем `configuration`, который отдал WebKit в
//  `createWebViewWith`, — только так WebKit связывает его с opener'ом, а cookie
//  (и итоговый `oauth_token`) пишутся в общий с родителем store.
//

import Cocoa
import WebKit

final class PopupWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate {
  let webView: WKWebView

  private let onClose: (PopupWindowController) -> Void

  private var titleObservation: NSKeyValueObservation?
  private var popups: [PopupWindowController] = []

  init(configuration: WKWebViewConfiguration,
       windowFeatures: WKWindowFeatures,
       parent: NSWindow?,
       userAgent: String?,
       onClose: @escaping (PopupWindowController) -> Void) {
    let width = CGFloat(windowFeatures.width?.doubleValue ?? 520)
    let height = CGFloat(windowFeatures.height?.doubleValue ?? 680)
    let rect = NSRect(x: 0, y: 0, width: width, height: height)

    webView = WKWebView(frame: rect, configuration: configuration)
    webView.customUserAgent = userAgent
    self.onClose = onClose

    let window = NSWindow(
      contentRect: rect,
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = webView
    super.init(window: window)

    window.delegate = self
    webView.uiDelegate = self
    titleObservation = webView.observe(\.title, options: [.new]) { [weak window] webView, _ in
      window?.title = webView.title ?? ""
    }

    // По центру над окном, которое открыло попап, — как в браузере.
    if let parent = parent {
      let frame = window.frame
      window.setFrameOrigin(NSPoint(
        x: parent.frame.midX - frame.width / 2,
        y: parent.frame.midY - frame.height / 2))
    } else {
      window.center()
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // window.close() из страницы провайдера после успешного входа.
  func webViewDidClose(_ webView: WKWebView) {
    close()
  }

  // Вложенному попапу тоже нужен собственный opener, не навигация родителя.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard navigationAction.targetFrame == nil, let parent = window else { return nil }
    let popup = PopupWindowController(
      configuration: configuration,
      windowFeatures: windowFeatures,
      parent: parent,
      userAgent: webView.customUserAgent
    ) { [weak self] closed in
      self?.popups.removeAll { $0 === closed }
    }
    popups.append(popup)
    popup.showWindow(nil)
    return popup.webView
  }

  func windowWillClose(_ notification: Notification) {
    let open = popups
    popups.removeAll()
    open.forEach { $0.close() }
    titleObservation = nil
    webView.stopLoading()
    webView.uiDelegate = nil
    onClose(self)
  }
}
