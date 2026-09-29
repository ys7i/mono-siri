import Foundation

/// Wikipedia のウィキテキストと本文を、問いかけ用の文章に整える小道具。
enum WikiText {
    /// 答えを伏せる記号
    static let mask = "〇〇〇"
    /// 置き換えの途中で使う目印（本文に出てこない文字列）
    private static let token = "\u{E000}MASK\u{E001}"

    struct Link {
        /// リンク先の記事名（# 以降は除く）
        let target: String
        /// 表示される文字
        let display: String
        /// 元の文字列の中の範囲（`[[` から `]]` まで）
        let range: Range<String.Index>
    }

    // MARK: - ウィキテキスト

    /// ウィキテキストの中のリンクをすべて返す（ファイルやカテゴリは除く）
    static func links(in text: String) -> [Link] {
        matches(of: #"\[\[([^\[\]|]+)(?:\|([^\[\]]*))?\]\]"#, in: text).compactMap { match -> Link? in
            guard match.groups.count >= 2, let rawTarget = match.groups[0] else { return nil }
            let target = rawTarget.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if target.isEmpty || target.contains(":") { return nil }
            var display = rawTarget
            if let label = match.groups[1], !label.isEmpty { display = label }
            return Link(target: target, display: display, range: match.range)
        }
    }

    /// ウィキテキストを、画面に出せる普通の文章にする
    static func plain(_ wikitext: String) -> String {
        var s = wikitext
        s = replacing(#"<!--[\s\S]*?-->"#, in: s, with: "")
        s = replacing(#"<ref[^>]*/>"#, in: s, with: "")
        s = replacing(#"<ref[^>]*>[\s\S]*?</ref>"#, in: s, with: "")
        // テンプレートは入れ子になるので、内側から何度か消す
        for _ in 0..<4 {
            s = replacing(#"\{\{[^{}]*\}\}"#, in: s, with: "")
        }
        s = replacing(#"\[\[(?:ファイル|画像|File|Image|Category|カテゴリ):[^\]]*\]\]"#, in: s, with: "")
        s = replacing(#"\[\[[^\[\]|]+\|([^\[\]]*)\]\]"#, in: s, with: "$1")
        s = replacing(#"\[\[([^\[\]]+)\]\]"#, in: s, with: "$1")
        s = replacing(#"\[https?://[^\s\]]+\s?([^\]]*)\]"#, in: s, with: "$1")
        s = s.replacingOccurrences(of: "'''", with: "").replacingOccurrences(of: "''", with: "")
        s = replacing(#"<[^>]+>"#, in: s, with: "")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = replacing(#"[ \t]+"#, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ウィキテキストの一部（range）を伏せて、普通の文章にする
    static func plain(_ wikitext: String, masking range: Range<String.Index>) -> String {
        var s = wikitext
        s.replaceSubrange(range, with: token)
        return tidyMask(plain(s).replacingOccurrences(of: token, with: mask))
    }

    // MARK: - 本文

    /// 本文の中の記事名を伏せる。伏せられなかったら nil
    static func cloze(_ text: String, answer title: String) -> String? {
        let name = WikipediaClient.baseName(title)
        var variants = [name, name.replacingOccurrences(of: " ", with: ""), name.replacingOccurrences(of: "・", with: "")]
        variants = Array(Set(variants)).filter { $0.count >= 1 }.sorted { $0.count > $1.count }

        var s = text
        for variant in variants {
            s = s.replacingOccurrences(of: variant, with: mask)
        }
        guard s.contains(mask) else { return nil }
        return tidyMask(s)
    }

    /// 最初の何文かだけにする
    static func sentences(_ text: String, count: Int, limit: Int = 160) -> String {
        var parts: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "。" {
                parts.append(current)
                current = ""
                if parts.count >= count { break }
            }
        }
        if parts.isEmpty { parts = [current] }
        let joined = parts.joined()
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }

    // MARK: - 内部

    /// 「〇〇〇（よみがな、英: …）は」のような読みの括弧は答えのヒントになるので消す
    private static func tidyMask(_ text: String) -> String {
        let s = replacing("(?:" + mask + "){2,}", in: text, with: mask)
        var out = ""
        var rest = Substring(s)
        while let found = rest.range(of: mask) {
            out += rest[..<found.upperBound]
            rest = rest[found.upperBound...]
            // 直後の括弧を、入れ子も含めて対応する閉じ括弧まで取り除く
            let afterSpace = rest.drop(while: { $0 == " " })
            guard let first = afterSpace.first, first == "（" || first == "(" else { continue }
            var depth = 0
            var end: Substring.Index?
            for index in afterSpace.indices {
                let ch = afterSpace[index]
                if ch == "（" || ch == "(" { depth += 1 }
                if ch == "）" || ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = afterSpace.index(after: index)
                        break
                    }
                }
            }
            if let end { rest = afterSpace[end...] }
        }
        out += rest
        return out
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// 正規表現に一致した部分の、各グループの文字列と全体の範囲を返す
    private static func matches(of pattern: String, in text: String) -> [(groups: [String?], range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let whole = Range(match.range, in: text) else { return nil }
            var groups: [String?] = []
            for i in 1..<max(match.numberOfRanges, 1) {
                if let r = Range(match.range(at: i), in: text) {
                    groups.append(String(text[r]))
                } else {
                    groups.append(nil)
                }
            }
            return (groups, whole)
        }
    }

    /// ウィキテキストの `'''…'''`（太字）の最初の範囲
    static func firstBoldRange(in text: String) -> (range: Range<String.Index>, inner: String)? {
        guard let match = matches(of: #"'''(.+?)'''"#, in: text).first, let inner = match.groups.first ?? nil else { return nil }
        return (match.range, inner)
    }
}
