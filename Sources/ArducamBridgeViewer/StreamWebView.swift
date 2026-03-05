import SwiftUI
import WebKit

enum StreamMessageKind: String {
    case status
    case live
    case fallback
    case error
}

struct StreamStatusUpdate {
    let kind: StreamMessageKind
    let message: String
}

struct StreamWebView: NSViewRepresentable {
    let streamURL: String
    let snapshotURL: String
    let reloadToken: UUID
    let onStatusChange: (StreamStatusUpdate) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatusChange: onStatusChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.bridgeName)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let fingerprint = "\(streamURL)|\(snapshotURL)|\(reloadToken.uuidString)"
        guard context.coordinator.lastFingerprint != fingerprint else { return }

        context.coordinator.lastFingerprint = fingerprint
        context.coordinator.load(streamURL: streamURL, snapshotURL: snapshotURL)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.bridgeName)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let bridgeName = "viewerBridge"

        var webView: WKWebView?
        var lastFingerprint = ""

        private let onStatusChange: (StreamStatusUpdate) -> Void

        init(onStatusChange: @escaping (StreamStatusUpdate) -> Void) {
            self.onStatusChange = onStatusChange
        }

        func load(streamURL: String, snapshotURL: String) {
            let html = Self.viewerHTML(
                streamURL: streamURL,
                snapshotURL: snapshotURL
            )

            webView?.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard
                message.name == Self.bridgeName,
                let payload = message.body as? [String: Any],
                let rawKind = payload["kind"] as? String,
                let kind = StreamMessageKind(rawValue: rawKind),
                let text = payload["message"] as? String
            else {
                return
            }

            onStatusChange(StreamStatusUpdate(kind: kind, message: text))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onStatusChange(StreamStatusUpdate(kind: .error, message: "Preview failed to render: \(error.localizedDescription)"))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onStatusChange(StreamStatusUpdate(kind: .error, message: "Preview failed to start: \(error.localizedDescription)"))
        }

        private static func viewerHTML(streamURL: String, snapshotURL: String) -> String {
            let safeStream = jsStringLiteral(streamURL)
            let safeSnapshot = jsStringLiteral(snapshotURL)

            return """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <style>
                :root {
                  color-scheme: dark;
                  --bg-a: #0b1216;
                  --bg-b: #131a1c;
                  --panel: rgba(255, 255, 255, 0.05);
                  --stroke: rgba(255, 255, 255, 0.08);
                  --text: #f3efe7;
                  --muted: rgba(243, 239, 231, 0.62);
                  --accent: #f1a34f;
                }
                * { box-sizing: border-box; }
                html, body {
                  width: 100%;
                  height: 100%;
                  margin: 0;
                  overflow: hidden;
                  background:
                    radial-gradient(circle at top left, rgba(241, 163, 79, 0.16), transparent 30%),
                    radial-gradient(circle at bottom right, rgba(52, 176, 166, 0.16), transparent 30%),
                    linear-gradient(140deg, var(--bg-a), var(--bg-b));
                  color: var(--text);
                  font-family: ui-rounded, system-ui, sans-serif;
                }
                .shell {
                  width: 100%;
                  height: 100%;
                  padding: 18px;
                  display: grid;
                }
                .frame {
                  position: relative;
                  width: 100%;
                  height: 100%;
                  border-radius: 22px;
                  overflow: hidden;
                  background: var(--panel);
                  border: 1px solid var(--stroke);
                  display: flex;
                  align-items: center;
                  justify-content: center;
                }
                img {
                  width: 100%;
                  height: 100%;
                  object-fit: contain;
                  display: none;
                }
                .overlay {
                  position: absolute;
                  top: 18px;
                  left: 18px;
                  padding: 10px 12px;
                  border-radius: 999px;
                  background: rgba(0, 0, 0, 0.38);
                  border: 1px solid rgba(255, 255, 255, 0.08);
                  color: var(--muted);
                  font-size: 12px;
                  letter-spacing: 0.08em;
                  text-transform: uppercase;
                }
                .placeholder {
                  max-width: 32rem;
                  padding: 20px;
                  text-align: center;
                  color: var(--muted);
                  line-height: 1.55;
                }
                .placeholder strong {
                  display: block;
                  margin-bottom: 8px;
                  color: var(--text);
                  font-size: 1.25rem;
                  letter-spacing: 0.01em;
                }
              </style>
            </head>
            <body>
              <div class="shell">
                <div class="frame">
                  <img id="feed" alt="Pi camera feed">
                  <div id="badge" class="overlay">Connecting</div>
                  <div id="placeholder" class="placeholder">
                    <strong>Waiting for the Pi feed</strong>
                    The preview will switch to live MJPEG when the endpoint responds. If not, it will retry on the snapshot fallback.
                  </div>
                </div>
              </div>
              <script>
                const streamUrl = \(safeStream);
                const snapshotUrl = \(safeSnapshot);
                const image = document.getElementById("feed");
                const badge = document.getElementById("badge");
                const placeholder = document.getElementById("placeholder");
                let fallbackInterval = null;
                let liveRetryTimeout = null;
                let firstFrameWatchdog = null;
                let mode = "boot";

                function post(kind, message) {
                  window.webkit.messageHandlers.viewerBridge.postMessage({ kind, message });
                }

                function updateBadge(text) {
                  badge.textContent = text;
                }

                function cacheBust(url) {
                  const divider = url.includes("?") ? "&" : "?";
                  return `${url}${divider}ts=${Date.now()}`;
                }

                function showFrame() {
                  image.style.display = "block";
                  placeholder.style.display = "none";
                }

                function clearFallback() {
                  if (fallbackInterval !== null) {
                    window.clearInterval(fallbackInterval);
                    fallbackInterval = null;
                  }
                }

                function clearWatchdog() {
                  if (firstFrameWatchdog !== null) {
                    window.clearTimeout(firstFrameWatchdog);
                    firstFrameWatchdog = null;
                  }
                }

                function clearLiveRetry() {
                  if (liveRetryTimeout !== null) {
                    window.clearTimeout(liveRetryTimeout);
                    liveRetryTimeout = null;
                  }
                }

                function scheduleLiveRetry() {
                  clearLiveRetry();
                  liveRetryTimeout = window.setTimeout(() => {
                    if (mode === "fallback") {
                      start(true);
                    }
                  }, 5000);
                }

                function beginFallback(reason) {
                  clearFallback();
                  clearWatchdog();

                  if (!snapshotUrl) {
                    updateBadge("Feed error");
                    post("error", `${reason} No snapshot fallback URL is configured.`);
                    return;
                  }

                  mode = "fallback";
                  updateBadge("Snapshot fallback");
                  post("fallback", reason);

                  const refreshSnapshot = () => {
                    image.src = cacheBust(snapshotUrl);
                  };

                  refreshSnapshot();
                  fallbackInterval = window.setInterval(refreshSnapshot, 2500);
                  scheduleLiveRetry();
                }

                image.onload = () => {
                  showFrame();

                  if (mode === "fallback") {
                    updateBadge("Snapshot fallback");
                    post("fallback", "Snapshot fallback is active.");
                  } else {
                    clearLiveRetry();
                    updateBadge("Live MJPEG");
                    post("live", "Live MJPEG stream connected.");
                  }
                  clearWatchdog();
                };

                image.onerror = () => {
                  if (mode === "fallback") {
                    post("error", "Snapshot refresh failed. Check the Pi stream server.");
                    scheduleLiveRetry();
                  } else {
                    beginFallback("MJPEG stream unavailable. Falling back to snapshots.");
                  }
                };

                function start(isRetry = false) {
                  clearLiveRetry();
                  clearFallback();
                  clearWatchdog();
                  mode = "live";
                  updateBadge(isRetry ? "Retrying live" : "Connecting");
                  post("status", isRetry ? `Retrying ${streamUrl}` : `Opening ${streamUrl}`);
                  image.src = cacheBust(streamUrl);

                  firstFrameWatchdog = window.setTimeout(() => {
                    if (mode === "live") {
                      beginFallback("MJPEG stream timed out. Falling back to snapshots.");
                    }
                  }, 6000);
                }

                start();
              </script>
            </body>
            </html>
            """
        }

        private static func jsStringLiteral(_ string: String) -> String {
            let escaped = string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")

            return "\"\(escaped)\""
        }
    }
}
