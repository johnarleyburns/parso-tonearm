import SwiftUI

enum Typography {
    static let display = Font.largeTitle.weight(.heavy)
    static let title = Font.title2.weight(.bold)
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let caption = Font.caption
    static let mono = Font.caption.monospacedDigit()
}

struct Metrics {
    static let cornerSmall: CGFloat = 10
    static let glassCornerRadius: CGFloat = 18
    static let minimumHitTarget: CGFloat = 44
    static let artworkSmall: CGFloat = 44
    static let rowHeight: CGFloat = 56
    static let chipHeight: CGFloat = 30
}

struct ScaledMetrics {
    @ScaledMetric(relativeTo: .body) var artworkSmall: CGFloat = 44
    @ScaledMetric(relativeTo: .body) var rowHeight: CGFloat = 56
    @ScaledMetric(relativeTo: .body) var chipHeight: CGFloat = 30
}
