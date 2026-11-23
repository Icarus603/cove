//
//  MarketsFormat.swift
//  boringNotch
//

import Foundation

enum MarketsFormat {
    /// Enough digits to be useful at any magnitude: 67,432.10 / 3.4521 / 0.00001234.
    static func price(_ value: Double) -> String {
        let digits: Int
        switch abs(value) {
        case 1000...: digits = 2
        case 1..<1000: digits = 3
        case 0.01..<1: digits = 4
        default: digits = 8
        }
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.automatic))
    }

    /// Axis labels: no decimals once prices are in the thousands, so they fit the narrow gutter.
    static func axisPrice(_ value: Double) -> String {
        abs(value) >= 1000 ? value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic)) : price(value)
    }

    /// A small difference such as a spread: significant digits instead of a fixed number of decimals.
    static func spread(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...4)))
    }

    static func percent(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + value.formatted(.number.precision(.fractionLength(2))) + "%"
    }

    static func money(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
    }

    /// 1.23K / 4.5M / 6.7B.
    static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
    }

    /// Default colour convention: red up in Chinese locales, green up elsewhere.
    static var defaultRedUp: Bool { Locale.current.language.languageCode?.identifier == "zh" }
}
