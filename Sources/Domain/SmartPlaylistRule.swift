import Foundation
import GRDB

public struct SmartPlaylistRule: Equatable, Codable {
    public var field: SmartPlaylistField
    public var op: SmartPlaylistOperator
    public var value: SmartPlaylistValue?
    public var upperValue: SmartPlaylistValue?

    public init(field: SmartPlaylistField,
         op: SmartPlaylistOperator,
         value: SmartPlaylistValue? = nil,
         upperValue: SmartPlaylistValue? = nil) {
        self.field = field
        self.op = op
        self.value = value
        self.upperValue = upperValue
    }

    public func matches(_ row: TrackRow) -> Bool {
        let fieldValue = field.value(in: row)
        switch op {
        case .contains:
            return fieldValue.normalizedText.contains(requiredText())
        case .notContains:
            return !fieldValue.normalizedText.contains(requiredText())
        case .equals:
            return equals(fieldValue)
        case .notEquals:
            return !equals(fieldValue)
        case .beginsWith:
            return fieldValue.normalizedText.hasPrefix(requiredText())
        case .endsWith:
            return fieldValue.normalizedText.hasSuffix(requiredText())
        case .greaterThan:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left > right
        case .greaterThanOrEqual:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left >= right
        case .lessThan:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left < right
        case .lessThanOrEqual:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left <= right
        case .between:
            guard let left = fieldValue.numberValue,
                  let first = value?.numberValue,
                  let second = upperValue?.numberValue else { return false }
            let lower = min(first, second)
            let upper = max(first, second)
            return lower <= left && left <= upper
        case .isEmpty:
            return fieldValue.isEmpty
        case .isNotEmpty:
            return !fieldValue.isEmpty
        }
    }

    public func sql(builder: inout SmartPlaylistSQLBuilder) -> String {
        let fieldSQL = field.sql
        switch op {
        case .contains:
            return "\(fieldSQL.textExpression) LIKE \(builder.bind(likePattern(requiredText()))) ESCAPE '\\'"
        case .notContains:
            return "\(fieldSQL.textExpression) NOT LIKE \(builder.bind(likePattern(requiredText()))) ESCAPE '\\'"
        case .equals:
            switch field.kind {
            case .text:
                return "\(fieldSQL.textExpression) = \(builder.bind(requiredText()))"
            case .number:
                guard let value = value?.numberValue else { return "0 = 1" }
                return "\(fieldSQL.expression) = \(builder.bind(value))"
            }
        case .notEquals:
            switch field.kind {
            case .text:
                return "\(fieldSQL.textExpression) != \(builder.bind(requiredText()))"
            case .number:
                guard let value = value?.numberValue else { return "1 = 1" }
                return "(\(fieldSQL.expression) IS NULL OR \(fieldSQL.expression) != \(builder.bind(value)))"
            }
        case .beginsWith:
            return "\(fieldSQL.textExpression) LIKE \(builder.bind(prefixPattern(requiredText()))) ESCAPE '\\'"
        case .endsWith:
            return "\(fieldSQL.textExpression) LIKE \(builder.bind(suffixPattern(requiredText()))) ESCAPE '\\'"
        case .greaterThan:
            return numericSQL(fieldSQL, ">", builder: &builder)
        case .greaterThanOrEqual:
            return numericSQL(fieldSQL, ">=", builder: &builder)
        case .lessThan:
            return numericSQL(fieldSQL, "<", builder: &builder)
        case .lessThanOrEqual:
            return numericSQL(fieldSQL, "<=", builder: &builder)
        case .between:
            guard field.kind == .number else { return "0 = 1" }
            guard let first = value?.numberValue, let second = upperValue?.numberValue else { return "0 = 1" }
            let lower = min(first, second)
            let upper = max(first, second)
            return "(\(fieldSQL.numericExpression) >= \(builder.bind(lower)) AND \(fieldSQL.numericExpression) <= \(builder.bind(upper)))"
        case .isEmpty:
            switch field.kind {
            case .text:
                return "TRIM(COALESCE(\(fieldSQL.expression), '')) = ''"
            case .number:
                return "\(fieldSQL.expression) IS NULL"
            }
        case .isNotEmpty:
            switch field.kind {
            case .text:
                return "TRIM(COALESCE(\(fieldSQL.expression), '')) != ''"
            case .number:
                return "\(fieldSQL.expression) IS NOT NULL"
            }
        }
    }

    private func equals(_ fieldValue: SmartPlaylistFieldValue) -> Bool {
        switch field.kind {
        case .text:
            return fieldValue.normalizedText == requiredText()
        case .number:
            guard let left = fieldValue.numberValue, let right = value?.numberValue else { return false }
            return left == right
        }
    }

    private func numericSQL(_ fieldSQL: SmartPlaylistFieldSQL,
                            _ comparison: String,
                            builder: inout SmartPlaylistSQLBuilder) -> String {
        guard field.kind == .number else { return "0 = 1" }
        guard let value = value?.numberValue else { return "0 = 1" }
        return "\(fieldSQL.numericExpression) \(comparison) \(builder.bind(value))"
    }

    private func requiredText() -> String {
        (value?.textValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func likePattern(_ value: String) -> String {
        "%\(escapedLike(value))%"
    }

    private func prefixPattern(_ value: String) -> String {
        "\(escapedLike(value))%"
    }

    private func suffixPattern(_ value: String) -> String {
        "%\(escapedLike(value))"
    }

    private func escapedLike(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "%": escaped.append("\\%")
            case "_": escaped.append("\\_")
            case "\\": escaped.append("\\\\")
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

public enum SmartPlaylistOperator: String, Codable, CaseIterable {
    case contains
    case notContains
    case equals
    case notEquals
    case beginsWith
    case endsWith
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    case between
    case isEmpty
    case isNotEmpty
}
