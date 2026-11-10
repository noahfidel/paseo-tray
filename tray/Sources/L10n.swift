import Foundation

/// Minimal localization: English by default, Chinese when the user's
/// preferred language starts with "zh".
let isChineseUI: Bool = {
    (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
}()

func L(_ en: String, _ zh: String) -> String {
    isChineseUI ? zh : en
}
