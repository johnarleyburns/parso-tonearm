import Foundation
import GRDB

public struct SmartPlaylistQuery {
    public var sql: String
    public var arguments: StatementArguments
}

public struct SmartPlaylistFieldSQL {
    public var expression: String
    public var kind: SmartPlaylistFieldKind

    public var textExpression: String {
        "LOWER(COALESCE(CAST(\(expression) AS TEXT), ''))"
    }

    public var numericExpression: String {
        kind == .number ? expression : "CAST(\(expression) AS REAL)"
    }
}

public struct SmartPlaylistFieldValue: Equatable {
    private var storage: Storage

    private enum Storage: Equatable {
        case text(String?)
        case number(Double?)
    }

    public static func text(_ value: String?) -> SmartPlaylistFieldValue {
        SmartPlaylistFieldValue(storage: .text(value))
    }

    public static func number(_ value: Double?) -> SmartPlaylistFieldValue {
        SmartPlaylistFieldValue(storage: .number(value))
    }

    public var isEmpty: Bool {
        switch storage {
        case .text(let value):
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .number(let value):
            return value == nil
        }
    }

    public var textValue: String {
        switch storage {
        case .text(let value):
            return value ?? ""
        case .number(let value):
            return value.map(Self.formatNumber) ?? ""
        }
    }

    public var normalizedText: String {
        textValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public var numberValue: Double? {
        switch storage {
        case .text:
            return nil
        case .number(let value):
            return value
        }
    }

    public static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int64(value))
        }
        return String(value)
    }
}

public struct SmartPlaylistSQLBuilder {
    public private(set) var arguments = StatementArguments()

    public mutating func bind(_ value: (any DatabaseValueConvertible)?) -> String {
        _ = arguments.append(contentsOf: StatementArguments([value]))
        return "?"
    }
}
