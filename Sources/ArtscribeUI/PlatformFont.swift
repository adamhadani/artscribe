#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The platform's concrete font class, for the one thing SwiftUI cannot do:
/// **measure text before drawing it.**
///
/// `CueLabelLayout` decides which track names fit and which have to be dropped,
/// and it cannot make that decision without a width. SwiftUI has no synchronous
/// measurement API, so the label widths come from `NSAttributedString.size()`,
/// which needs a real font object rather than SwiftUI's opaque `Font`.
///
/// The two classes are interchangeable for this purpose — same
/// `systemFont(ofSize:weight:)`, same metrics through
/// `NSAttributedString`/`NSString` sizing — so a typealias is the whole
/// adaptation.
#if os(macOS)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif
