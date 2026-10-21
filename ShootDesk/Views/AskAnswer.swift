import SwiftUI
import Charts

/// One piece of an answer, after the markers Claude was asked to use are turned into pictures.
enum AnswerBlock {
    case text(String)
    case list([String], numbered: Bool)
    case shoot(Int)              // [[shoot 1855]]
    case agent(String)           // [[agent Molly Armando]]
    case chart(ChartSpec)        // a ```chart {...}``` block
    case chartPending            // the chart is still streaming in
}

/// What Claude sends for a chart (see `AskContext.system`).
struct ChartSpec: Decodable {
    struct Point: Decodable, Identifiable {
        let label: String
        let value: Double
        let series: String?
        var id: String { (series ?? "") + "|" + label }
    }
    let kind: String?
    let title: String?
    let unit: String?
    let points: [Point]
    var isLine: Bool { kind == "line" }
    var hasSeries: Bool { Set(points.compactMap(\.series)).count > 1 }
}

struct ParsedAnswer {
    var blocks: [AnswerBlock] = []
    var followUps: [String] = []
    /// The answer as plain text, for Copy and Share (cards become "#1855 6 Morrison Way").
    var plain = ""
}

enum AnswerParser {
    /// Splits Claude's answer into blocks. While it's still streaming, a half-written marker or chart
    /// is held back instead of showing as raw text.
    static func parse(_ raw: String, streaming: Bool, jobs: [Job] = []) -> ParsedAnswer {
        var out = ParsedAnswer()
        var text = raw
        if streaming, let open = text.range(of: "[[", options: .backwards), text[open.lowerBound...].range(of: "]]") == nil {
            text = String(text[..<open.lowerBound])
        }

        var plainLines: [String] = []
        var paragraph: [String] = []
        var items: [String] = []
        var numbered = false

        func flushParagraph() {
            if !paragraph.isEmpty { out.blocks.append(.text(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushList() {
            if !items.isEmpty { out.blocks.append(.list(items, numbered: numbered)); items = [] }
        }
        func flushAll() { flushParagraph(); flushList() }

        var lines = text.components(separatedBy: "\n")[...]
        while let line = lines.popFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)

            // A chart: ```chart, then JSON, then ```.
            if t.hasPrefix("```chart") {
                flushAll()
                var json: [String] = []
                var closed = false
                while let l = lines.popFirst() {
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { closed = true; break }
                    json.append(l)
                }
                if let d = json.joined(separator: "\n").data(using: .utf8),
                   let spec = try? JSONDecoder().decode(ChartSpec.self, from: d), !spec.points.isEmpty {
                    out.blocks.append(.chart(spec))
                    if let title = spec.title { plainLines.append("[Chart: \(title)]") }
                } else if !closed && streaming {
                    out.blocks.append(.chartPending)
                }
                continue
            }
            if t.hasPrefix("```") { continue }   // stray fences

            if let inner = marker(t) {
                if inner.lowercased().hasPrefix("next:") {
                    out.followUps = inner.dropFirst(5).split(separator: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3).map { $0 }
                    continue
                }
                if inner.lowercased().hasPrefix("shoot"), let n = Int(inner.dropFirst(5).filter(\.isNumber)) {
                    flushAll()
                    out.blocks.append(.shoot(n))
                    plainLines.append("#\(n)")
                    continue
                }
                if inner.lowercased().hasPrefix("agent") {
                    let name = inner.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { flushAll(); out.blocks.append(.agent(name)) }
                    continue
                }
                continue
            }

            if t.isEmpty { flushAll(); plainLines.append(""); continue }
            if let item = bullet(t) {
                flushParagraph()
                if !items.isEmpty && numbered { flushList() }
                numbered = false
                items.append(item)
                plainLines.append("• " + item)
                continue
            }
            if let item = numberedItem(t) {
                flushParagraph()
                if !items.isEmpty && !numbered { flushList() }
                numbered = true
                items.append(item)
                plainLines.append("\(items.count). " + item)
                continue
            }
            flushList()
            paragraph.append(line.hasPrefix("#") ? t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : line)
            plainLines.append(t)
        }
        flushAll()
        out.plain = plainLines.joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    /// "[[shoot 1855]]" → "shoot 1855", for a line that is only a marker.
    private static func marker(_ t: String) -> String? {
        guard t.hasPrefix("[["), t.hasSuffix("]]"), t.count > 4 else { return nil }
        return String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    }
    private static func bullet(_ t: String) -> String? {
        for p in ["- ", "* ", "• "] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return nil
    }
    private static func numberedItem(_ t: String) -> String? {
        guard let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), dot > t.startIndex,
              t[..<dot].allSatisfy(\.isNumber), t[..<dot].count <= 2 else { return nil }
        let rest = t[t.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Bold and italics; markers left inside a sentence are dropped rather than shown raw.
    static func inline(_ s: String) -> AttributedString {
        let tidy = s.replacingOccurrences(of: "\\[\\[[^\\]]*\\]\\]", with: "", options: .regularExpression)
        return (try? AttributedString(markdown: tidy, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(tidy)
    }
}

/// A small chart inside an answer: bars or a line, one or two series.
struct AnswerChart: View {
    let spec: ChartSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            Chart(spec.points) { p in
                if spec.isLine {
                    LineMark(x: .value("Label", p.label), y: .value("Value", p.value))
                        .foregroundStyle(by: .value("Series", p.series ?? ""))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Label", p.label), y: .value("Value", p.value))
                        .foregroundStyle(by: .value("Series", p.series ?? ""))
                } else if spec.hasSeries {
                    BarMark(x: .value("Label", p.label), y: .value("Value", p.value))
                        .foregroundStyle(by: .value("Series", p.series ?? ""))
                        .position(by: .value("Series", p.series ?? ""))
                        .cornerRadius(3)
                } else {
                    BarMark(x: .value("Label", p.label), y: .value("Value", p.value))
                        .foregroundStyle(Theme.accent)
                        .cornerRadius(3)
                }
            }
            .chartForegroundStyleScale(range: [Color(.systemGray3), Theme.accent, Color.orange, Color.green])
            .chartLegend(spec.hasSeries ? .visible : .hidden)
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(short(d)).font(.caption2) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption2) }
            }
            .frame(height: 180)
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func short(_ d: Double) -> String {
        let money = spec.unit == "$"
        let s: String
        if abs(d) >= 1000 { s = String(format: d.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0fk" : "%.1fk", d / 1000) }
        else { s = String(format: "%.0f", d) }
        return money ? "$" + s : s
    }
}
