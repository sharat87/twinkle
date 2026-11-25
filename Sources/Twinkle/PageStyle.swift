import WebKit

/// Twinkle's own CSS for every page and frame: thin scrollbars, drawn in the
/// element's text colour on a transparent track.
///
/// It goes in as a WebKit user stylesheet, which the page can't see or
/// remove and which a Content-Security-Policy doesn't block. WebKit only has
/// these as private API; if it's ever gone, pages keep their own scrollbars.
@MainActor
enum PageStyle {
    static let css = """
    * {
      scrollbar-width: thin !important;
      scrollbar-color: currentColor transparent !important;
    }
    """

    private static let sheet: NSObject? = {
        guard let cls = NSClassFromString("_WKUserStyleSheet") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("initWithSource:forMainFrameOnly:")
        guard let method = class_getInstanceMethod(cls, selector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, NSString, Bool) -> Unmanaged<NSObject>?
        let initialise = unsafeBitCast(method_getImplementation(method), to: Init.self)
        let allocated = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        return initialise(allocated, selector, css as NSString, false)?.takeRetainedValue()
    }()

    static func install(_ controller: WKUserContentController) {
        let add = NSSelectorFromString("_addUserStyleSheet:")
        guard let sheet, controller.responds(to: add) else { return }
        let list = NSSelectorFromString("_userStyleSheets")
        if controller.responds(to: list),
           let existing = controller.perform(list)?.takeUnretainedValue() as? [NSObject],
           existing.contains(where: { $0 === sheet }) { return }
        controller.perform(add, with: sheet)
    }
}
