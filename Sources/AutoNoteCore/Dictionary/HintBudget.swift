import Foundation

public enum HintBudget {
    public static let whisperLimit = 224

    /// Conservative BPE estimate: ASCII alphanumeric run = ceil(len/4), whitespace = 0,
    /// other ASCII = 1, each non-ASCII scalar = 2.
    public static func estimateTokens(_ text: String) -> Int {
        var total = 0, run = 0
        func flush() { total += (run + 3) / 4; run = 0 }
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                let v = scalar.value
                let alnum = (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v)
                if alnum { run += 1; continue }
                flush()
                if !(v == 32 || (9...13).contains(v)) { total += 1 }
            } else {
                flush(); total += 2
            }
        }
        flush()
        return total
    }

    /// Takes terms from the front while they fit (each costs its tokens plus 1 for the ", " separator);
    /// stops at the first term that overflows, even if later ones are smaller.
    public static func fit(_ terms: [String], limit: Int = whisperLimit) -> (included: [String], dropped: [String]) {
        var used = 0, count = 0
        for term in terms {
            let cost = estimateTokens(term) + 1
            if used + cost > limit { break }
            used += cost; count += 1
        }
        return (Array(terms[..<count]), Array(terms[count...]))
    }
}
