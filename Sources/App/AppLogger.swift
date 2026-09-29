import os

enum AppLogger {
    static let app = Logger(subsystem: "guru.parso.platterhead", category: "app")
    static let artwork = Logger(subsystem: "guru.parso.platterhead", category: "artwork")
    static let ingest = Logger(subsystem: "guru.parso.platterhead", category: "ingest")
    static let onboarding = Logger(subsystem: "guru.parso.platterhead", category: "onboarding")
}
