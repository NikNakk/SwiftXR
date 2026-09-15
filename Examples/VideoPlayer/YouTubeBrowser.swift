@preconcurrency import WebKit
import AppKit
import Foundation

@MainActor
final class YouTubeBrowserController: NSObject {
    private static let width: CGFloat = 1024
    private static let height: CGFloat = 512
    private static let snapshotInterval: TimeInterval = 0.10

    private let webView: WKWebView
    private let window: NSWindow
    private var loaded = false
    private var snapshotPending = false
    private var needsSnapshot = true
    private var lastSnapshot = Date.distantPast
    private var textInputFocused = false
    private var isShutdown = false

    var onSnapshot: ((NSImage?) -> Void)?
    var onLaunchURL: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false

        let contentController = WKUserContentController()
        configuration.userContentController = contentController

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            configuration: configuration
        )
        webView.allowsMagnification = false

        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: Self.width, height: Self.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = webView

        super.init()

        contentController.add(self, name: "swiftXRVR")
        contentController.addUserScript(
            WKUserScript(
                source: Self.injectionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        webView.navigationDelegate = self
        window.orderFront(nil)
    }

    /// Break WebKit's strong script-message-handler ownership before the player
    /// terminates. This is explicit rather than `deinit` because AppKit/WebKit
    /// teardown APIs are MainActor-isolated in Swift 6.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "swiftXRVR")
        webView.navigationDelegate = nil
        window.orderOut(nil)
    }

    func open() {
        guard !isShutdown else { return }
        window.orderFront(nil)
        needsSnapshot = true
        onStatus?("Loading YouTube VR…")

        guard !loaded else { return }
        loaded = true
        guard let url = URL(string: "https://www.youtube.com/results?search_query=VR180+8K") else {
            return
        }
        webView.load(URLRequest(url: url))
        print("[youtube-ui] opened YouTube VR browser")
    }

    func close() {
        textInputFocused = false
        window.orderOut(nil)
    }

    func tick() {
        guard !isShutdown, !snapshotPending else { return }
        let now = Date()
        guard needsSnapshot || now.timeIntervalSince(lastSnapshot) >= Self.snapshotInterval else {
            return
        }

        needsSnapshot = false
        snapshotPending = true
        lastSnapshot = now

        webView.takeSnapshot(with: nil) { [weak self] image, error in
            Task { @MainActor in
                guard let self else { return }
                self.snapshotPending = false
                if let image {
                    self.onSnapshot?(image)
                } else if let error {
                    self.onStatus?("YouTube snapshot failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func pointerMoved() {
        if textInputFocused {
            maintainKeyboardFocus()
        }
    }

    func click(at normalizedPoint: SIMD2<Float>) {
        guard !isShutdown else { return }
        let u = min(max(Double(normalizedPoint.x), 0), 1)
        let v = min(max(Double(normalizedPoint.y), 0), 1)
        let x = u * Double(Self.width)
        let y = v * Double(Self.height)
        let script = """
        (() => {
          const e = document.elementFromPoint(\(String(format: "%.1f", x)), \(String(format: "%.1f", y)));
          if (!e) return '';
          if (e.focus) e.focus();
          e.click();
          return (e.tagName || '').toLowerCase();
        })()
        """

        webView.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                self.needsSnapshot = true
                if let tag = result as? String,
                   tag == "input" || tag == "textarea" {
                    self.textInputFocused = true
                    self.maintainKeyboardFocus()
                    print("[youtube-ui] keyboard focus sent to YouTube search field")
                } else {
                    self.textInputFocused = false
                }
            }
        }
    }

    func scroll(_ delta: SIMD2<Float>) {
        guard !isShutdown else { return }
        let amount = -Double(delta.y) * 220
        guard abs(amount) > 0.5 else { return }
        let script = "window.scrollBy(0, \(String(format: "%.1f", amount)));"
        webView.evaluateJavaScript(script, completionHandler: nil)
        needsSnapshot = true
    }

    func back() -> Bool {
        guard !isShutdown else { return false }
        textInputFocused = false
        if webView.canGoBack {
            webView.goBack()
            needsSnapshot = true
            return true
        }
        return false
    }

    private func maintainKeyboardFocus() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
    }

    private static let injectionScript = #"""
    (() => {
      const BUTTON_ID = 'swiftxr-psvr2-play-button';
      const isPlayableURL = value => {
        try {
          const u = new URL(value, location.href);
          const host = u.hostname.toLowerCase();
          const isYouTube = host === 'youtube.com' || host === 'www.youtube.com' || host.endsWith('.youtube.com');
          if (!isYouTube) return null;
          if (u.pathname === '/watch' && u.searchParams.get('v')) return u.href;
          if (u.pathname.startsWith('/shorts/')) return u.href;
        } catch (_) {}
        return null;
      };

      document.addEventListener('click', ev => {
        const target = ev.target instanceof Element ? ev.target : null;
        const anchor = target ? target.closest('a[href]') : null;
        if (!anchor) return;
        const playable = isPlayableURL(anchor.href);
        if (!playable) return;
        ev.preventDefault();
        ev.stopImmediatePropagation();
        window.webkit.messageHandlers.swiftXRVR.postMessage(playable);
      }, true);

      const install = () => {
        document.querySelectorAll('video').forEach(v => { v.muted = true; v.pause(); });
        const onVideo = location.pathname === '/watch' || location.pathname.startsWith('/shorts/');
        let button = document.getElementById(BUTTON_ID);
        if (!onVideo) {
          if (button) button.remove();
          return;
        }
        if (!button) {
          button = document.createElement('button');
          button.id = BUTTON_ID;
          button.textContent = '🥽 Play in PSVR2';
          Object.assign(button.style, {
            position: 'fixed', right: '24px', bottom: '76px', zIndex: '2147483647',
            border: '1px solid rgba(255,255,255,.32)', borderRadius: '14px',
            padding: '13px 18px', color: 'white', background: 'rgba(92,107,242,.96)',
            font: '600 16px -apple-system, BlinkMacSystemFont, sans-serif',
            boxShadow: '0 8px 28px rgba(0,0,0,.38)', cursor: 'pointer'
          });
          button.addEventListener('click', ev => {
            ev.preventDefault();
            ev.stopPropagation();
            window.webkit.messageHandlers.swiftXRVR.postMessage(location.href);
          }, true);
          document.documentElement.appendChild(button);
        }
      };

      install();
      new MutationObserver(install).observe(document.documentElement, {subtree:true, childList:true});
      window.addEventListener('yt-navigate-finish', install, true);
      setInterval(install, 1200);
    })();
    """#
}

extension YouTubeBrowserController: WKScriptMessageHandler, WKNavigationDelegate {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "swiftXRVR", let url = message.body as? String else { return }
        print("[youtube-ui] VR launch requested: \(url)")
        onLaunchURL?(url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        needsSnapshot = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        needsSnapshot = true
        onStatus?("YouTube VR")
    }
}
