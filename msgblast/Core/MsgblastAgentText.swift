import AppKit

/// The msgblast agent's replies as styled text: Markdown lists, headings, bold, italic, code and links.
public enum MsgblastAgentText {
    public static func render(_ markdown: String, size: CGFloat = NSFont.systemFontSize, color: NSColor = .labelColor,
                              weight: NSFont.Weight = .regular) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var body = Substring(line), prefix = "", heading = false
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.drop { $0 == " " }
            if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " {
                prefix = "•"; body = trimmed.dropFirst(2)
            } else if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), dot > trimmed.startIndex,
                      trimmed[..<dot].allSatisfy(\.isNumber), trimmed[trimmed.index(after: dot)...].first == " " {
                prefix = trimmed[...dot] + ""; body = trimmed[trimmed.index(dot, offsetBy: 2)...]
            } else if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }) {
                heading = true; body = trimmed[trimmed.index(after: space)...]
            }
            let rendered = NSMutableAttributedString()
            let paragraph = NSMutableParagraphStyle()
            if !prefix.isEmpty {
                let start = CGFloat(indent / 2) * 16, hang = start + 18
                paragraph.firstLineHeadIndent = start
                paragraph.headIndent = hang
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: hang)]
                rendered.append(NSAttributedString(string: prefix + "\t", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                                                         .foregroundColor: color]))
            }
            rendered.append(inline(String(body), size: size, color: color, weight: heading ? .semibold : weight))
            if index < lines.count - 1 { rendered.append(NSAttributedString(string: "\n")) }
            rendered.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: rendered.length))
            result.append(rendered)
        }
        return result
    }

    private static func inline(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
