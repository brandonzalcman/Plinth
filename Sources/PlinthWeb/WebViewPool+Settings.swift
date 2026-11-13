import WebKit
import PlinthSettings

extension WebViewPool {
    /// Applies every web-facing setting: called once at launch and after every change. Owned by the
    /// web-settings agent; this is the stub.
    public func apply(_ settings: AppSettings) {}
}
