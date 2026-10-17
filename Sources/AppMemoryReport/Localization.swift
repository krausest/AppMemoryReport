import Foundation
import MemoryCore

/// Bundle with the compiled `Localizable.xcstrings`. `scripts/make-app.sh` copies the
/// `.lproj` folders into the app itself, so the main bundle (and AppKit's standard
/// menus) knows the localizations; with `swift run` they stay in SwiftPM's resource bundle.
private let localizationBundle: Bundle = Bundle.main.bundleURL.pathExtension == "app"
    ? .main : preferredLocalization(of: .module)

/// Localized UI string; interpolations become format arguments (`"\(n) apps"` → `"%lld apps"`).
func localized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: localizationBundle)
}
