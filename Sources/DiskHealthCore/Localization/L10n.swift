//
//  L10n.swift
//  Disk Health
//
//  Copyright © 2026 Advandz Technologies, LLC.
//

import Foundation

// Localization notes
// - Every user-facing string goes through `String(localized:)` / `LocalizedStringResource`, which resolve
//   against `Bundle.main`. The build script compiles Resources/Localizable.xcstrings into the .app, so the
//   app and this library share one catalog. Outside the .app (swift test / swift run) the English source
//   text is used as-is.
// - Counts are interpolated as `Int` so they get the locale's grouping separator and plural rules.
//   Never interpolate a `Double` into a localized string (it formats as "%lf" → "12.500000"); format it
//   first with `fixed(_:)`.
// - Identity values (drive IDs, finding IDs, history keys, IOKit keys) are never localized.

extension Double {
    /// Locale-aware decimal with a fixed number of fraction digits ("1,234.5" / "1.234,5").
    public func fixed(_ digits: Int) -> String {
        formatted(.number.precision(.fractionLength(digits)))
    }

    /// Clamped conversion for 64/128-bit counters stored as Double.
    public var clampedInt: Int {
        guard isFinite else { return 0 }
        if self >= Double(Int.max) { return Int.max }
        if self <= Double(Int.min) { return Int.min }
        return Int(self)
    }
}

extension UInt64 {
    public var clampedInt: Int { self > UInt64(Int.max) ? Int.max : Int(self) }
}
