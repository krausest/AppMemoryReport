import Foundation

/// The `.lproj` folder of `bundle` that best matches the user's preferred languages,
/// as a bundle of its own, or `bundle` itself for the development language (English).
///
/// Foundation picks a resource bundle's language from the *main* bundle's localizations.
/// A command-line tool (or an app started with `swift run`) has none, so it would
/// always fall back to English.
public func preferredLocalization(of bundle: Bundle) -> Bundle {
    // The source language has no strings file of its own (keys are the English text).
    let available = Set(bundle.localizations).union(["en"])
    guard let language = Bundle.preferredLocalizations(
              from: Array(available), forPreferences: Locale.preferredLanguages).first,
          let path = bundle.path(forResource: language, ofType: "lproj"),
          let localized = Bundle(path: path)
    else { return bundle }
    return localized
}
