import os

enum TonearmLog {
    static let ingest = Logger(subsystem: "guru.parso.platterhead", category: "ingest")
    static let widgets = Logger(subsystem: "guru.parso.platterhead", category: "widgets")
}
