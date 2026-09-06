import Foundation

/// Parsers for REW text exports, used as ground truth by the validation
/// harness (brief §5.2: build the REW comparison harness early).
///
/// Supported inputs:
/// - "Export measurement as text": header lines starting with `*`, then rows
///   of `frequency SPL [phase]` (space, tab, comma, or semicolon separated).
/// - RT60 text export: rows of `band  EDT  T20  T30 …` under a header line;
///   we parse band center plus named columns.
///
/// Locale robustness: REW exports follow the host machine's locale, so
/// European files use decimal commas ("0,45") and typically semicolons or
/// whitespace as field separators. Per line: if commas appear but no dots,
/// commas are decimal separators; otherwise commas separate fields.
public enum REWImport {

    public struct FrequencyResponsePoint: Sendable {
        public let frequency: Double
        public let spl: Double
        public let phase: Double?
    }

    public struct RT60Row: Sendable {
        public let bandCenter: Double
        public let edt: Double?
        public let t20: Double?
        public let t30: Double?
    }

    public enum ImportError: Error, CustomStringConvertible {
        case empty
        case noParsableRows

        public var description: String {
            switch self {
            case .empty: return "File is empty"
            case .noParsableRows: return "No parsable data rows found"
            }
        }
    }

    // MARK: - Frequency response

    public static func parseFrequencyResponse(text: String) throws -> [FrequencyResponsePoint] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { throw ImportError.empty }

        var points: [FrequencyResponsePoint] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("*"), !trimmed.hasPrefix("#") else { continue }
            let fields = numericFields(of: trimmed)
            guard fields.count >= 2 else { continue }
            points.append(FrequencyResponsePoint(
                frequency: fields[0],
                spl: fields[1],
                phase: fields.count >= 3 ? fields[2] : nil
            ))
        }
        guard !points.isEmpty else { throw ImportError.noParsableRows }
        return points
    }

    // MARK: - RT60 table

    public static func parseRT60(text: String) throws -> [RT60Row] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { throw ImportError.empty }

        // Locate a header naming the columns, e.g. "Band  EDT  T20  T30".
        var edtColumn: Int?
        var t20Column: Int?
        var t30Column: Int?
        // Two header dialects exist:
        // - REW V5.40+: a prose block (no '*' prefixes) followed by a
        //   "Format is freq (Hz), BW (octaves), EDT (s), r, T20 (s), r, …"
        //   description line; data rows are whitespace-separated and contain
        //   non-numeric tokens ("1/3", "Forward") that count as columns.
        // - Older/tabular: a "Band  EDT  T20  T30" header row (tab- or
        //   space-separated, optionally with unit suffixes).
        enum HeaderStyle { case none, tabular, formatLine }
        var style = HeaderStyle.none
        var freqColumn = 0

        /// Parse one token as a number, accepting European decimal commas.
        func number(_ token: any StringProtocol) -> Double? {
            if let v = Double(token) { return v }
            if token.contains(","), !token.contains(".") {
                return Double(token.replacingOccurrences(of: ",", with: "."))
            }
            return nil
        }

        var rows: [RT60Row] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("*"), !trimmed.hasPrefix("#") else { continue }
            let lower = trimmed.lowercased()

            // V5.40-style column-description line. Names are comma-separated
            // and align 1:1 with whitespace-separated data-row tokens.
            if style == .none, lower.hasPrefix("format is") {
                let names = lower.dropFirst("format is".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                for (i, name) in names.enumerated() {
                    if name.hasPrefix("freq") || name.hasPrefix("band") { freqColumn = i }
                    if name.hasPrefix("edt"), edtColumn == nil { edtColumn = i }
                    if name.hasPrefix("t20"), t20Column == nil { t20Column = i }
                    if name.hasPrefix("t30"), t30Column == nil { t30Column = i }
                }
                style = .formatLine
                continue
            }

            // Tabular header row, e.g. "Band (Hz)\tEDT (s)\tT20 (s)\tT30 (s)".
            // Column indices must line up with the *numeric* fields of the
            // data rows: tab-separated headers split on tabs (units stay
            // inside their column token); space-separated headers drop
            // standalone unit tokens like "(s)".
            if style == .none, lower.contains("t20") || lower.contains("t30") || lower.contains("edt") {
                let columns: [String]
                if trimmed.contains("\t") {
                    columns = trimmed.split(separator: "\t")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                } else {
                    columns = trimmed.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
                        .map { $0.lowercased() }
                        .filter { !$0.isEmpty && !$0.hasPrefix("(") }
                }
                for (i, name) in columns.enumerated() {
                    if name.contains("edt") { edtColumn = i }
                    if name.contains("t20") { t20Column = i }
                    if name.contains("t30") { t30Column = i }
                }
                style = .tabular
                continue
            }

            // Prose metadata ("Dated: …", "Peak value: … at index …",
            // "Response measured over: 0.4 to 19,999.9 Hz") is never data.
            // Data rows in every known dialect are colon-free.
            if trimmed.contains(":") { continue }

            switch style {
            case .formatLine:
                // Token-indexed: non-numeric tokens ("1/3", "Forward") hold
                // their column position. The "full" summary row has a
                // non-numeric frequency and is skipped.
                let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard freqColumn < tokens.count,
                      let freq = number(tokens[freqColumn]), freq > 0
                else { continue }
                func pick(_ column: Int?) -> Double? {
                    guard let column, column < tokens.count,
                          let v = number(tokens[column]), v > 0 else { return nil }
                    return v
                }
                rows.append(RT60Row(
                    bandCenter: freq,
                    edt: pick(edtColumn),
                    t20: pick(t20Column),
                    t30: pick(t30Column)
                ))

            case .tabular, .none:
                let fields = numericFields(of: trimmed)
                guard fields.count >= 2, fields[0] > 0 else { continue }
                func pick(_ column: Int?) -> Double? {
                    guard let column, column < fields.count else { return nil }
                    let v = fields[column]
                    return v > 0 ? v : nil
                }
                rows.append(RT60Row(
                    bandCenter: fields[0],
                    edt: pick(edtColumn),
                    // Headerless two-column files: treat the second number as RT.
                    t20: pick(t20Column) ?? (style == .none ? fields[1] : nil),
                    t30: pick(t30Column)
                ))
            }
        }
        guard !rows.isEmpty else { throw ImportError.noParsableRows }
        return rows
    }

    // MARK: - Helpers

    /// Tokenize one data line into numbers, handling both dot-decimal and
    /// European comma-decimal formats.
    ///
    /// - A line with commas but no dots is comma-decimal: commas become dots
    ///   and only whitespace/tab/semicolon separate fields. (Splitting on
    ///   those commas would silently turn "0,45" into 0 and 45.)
    /// - A line containing dots uses commas, semicolons, and whitespace as
    ///   field separators.
    static func numericFields(of line: String) -> [Double] {
        let commaIsDecimal = line.contains(",") && !line.contains(".")
        let normalized = commaIsDecimal ? line.replacingOccurrences(of: ",", with: ".") : line
        return normalized
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" || (!commaIsDecimal && $0 == ",") })
            .compactMap { Double($0) }
    }
}
