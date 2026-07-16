import Foundation

public struct SearchQueryBuilder {
    public static let maxTerms = 32
    public static let maxScalarsPerTerm = 64

    public static func matchExpression(for input: String) -> String? {
        let terms = tokenize(input)
        guard !terms.isEmpty else { return nil }
        return terms
            .prefix(maxTerms)
            .map { "\"\(escaped($0))\"*" }
            .joined(separator: " ")
    }

    public static func tokenize(_ input: String) -> [String] {
        var terms: [String] = []
        var current = ""

        func finishTerm() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                terms.append(String(trimmed.unicodeScalars.prefix(maxScalarsPerTerm)))
            }
            current.removeAll(keepingCapacity: true)
        }

        for scalar in input.unicodeScalars {
            if isSearchScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                finishTerm()
            }
        }
        finishTerm()
        return terms
    }

    private static func escaped(_ term: String) -> String {
        term.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private static func isSearchScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.letters.contains(scalar)
            || CharacterSet.decimalDigits.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }
}
