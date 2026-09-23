import SwiftUI
import AppKit

/// Code editor for the pre/post-checkout blocks: zsh syntax colours, line numbers, Tab / ⇧Tab
/// indent, ⌘/ toggle comment, ⌘] ⌘[ shift, auto-indent on return, plain-text paste, no smart
/// quotes (a curly quote would break the script).
struct ShellEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = ShellTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.string = text
        textView.applyHighlighting()

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        textView.ruler = ruler
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        DispatchQueue.main.async { textView.scroll(.zero) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ShellTextView, textView.string != text else { return }
        let selection = textView.selectedRange()
        textView.string = text
        textView.applyHighlighting()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        textView.ruler?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ShellEditor
        init(_ parent: ShellEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ShellTextView else { return }
            parent.text = textView.string
            textView.applyHighlighting()
            textView.ruler?.needsDisplay = true
        }
    }
}

// MARK: - text view

final class ShellTextView: NSTextView {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    weak var ruler: LineNumberRuler?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        font = Self.font
        typingAttributes = [.font: Self.font, .foregroundColor: ShellTheme.plain]
        isRichText = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 6, height: 6)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyHighlighting() {
        guard let storage = textStorage else { return }
        ShellHighlighter.highlight(storage)
        typingAttributes = [.font: Self.font, .foregroundColor: ShellTheme.plain]
    }

    // MARK: editing commands

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    /// ⌘/ ⌘] ⌘[ resolved from the typed character, so they work on layouts where `/`, `]` or `[`
    /// need Shift or Option (AZERTY), which the menu's key equivalents alone do not match.
    /// The window offers the event to every view, so only the focused editor may take it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, flags.contains(.command), !flags.contains(.control) else {
            return super.performKeyEquivalent(with: event)
        }
        let typed = [event.characters, event.charactersIgnoringModifiers].compactMap { $0 }
        if typed.contains("/") { toggleComment(nil); return true }
        if typed.contains("]") { shiftRight(nil); return true }
        if typed.contains("[") { shiftLeft(nil); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func insertTab(_ sender: Any?) {
        if selectionSpansSeveralLines { shiftRight(sender) } else { insertText("  ", replacementRange: selectedRange()) }
    }

    override func insertBacktab(_ sender: Any?) { shiftLeft(sender) }

    override func insertNewline(_ sender: Any?) {
        let s = string as NSString
        let line = s.substring(with: s.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    @objc func shiftRight(_ sender: Any?) {
        transformSelectedLines { $0.isEmpty ? $0 : "  " + $0 }
    }

    @objc func shiftLeft(_ sender: Any?) {
        transformSelectedLines { line in
            if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
            if line.hasPrefix(" ") || line.hasPrefix("\t") { return String(line.dropFirst()) }
            return line
        }
    }

    @objc func toggleComment(_ sender: Any?) {
        let lines = selectedLines().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !lines.isEmpty && lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let indent = lines.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        transformSelectedLines { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allCommented {
                let ws = line.prefix { $0 == " " || $0 == "\t" }
                var rest = line.dropFirst(ws.count)
                rest = rest.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                return String(ws) + String(rest)
            }
            return String(line.prefix(indent)) + "# " + String(line.dropFirst(indent))
        }
    }

    private var selectionSpansSeveralLines: Bool {
        let sel = selectedRange()
        guard sel.length > 0 else { return false }
        return (string as NSString).substring(with: sel).contains("\n")
    }

    private func selectedLines() -> [String] {
        let s = string as NSString
        let block = s.substring(with: s.lineRange(for: selectedRange()))
        var lines = block.components(separatedBy: "\n")
        if block.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        let s = string as NSString
        let range = s.lineRange(for: selectedRange())
        let block = s.substring(with: range)
        let trailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }
        let out = lines.map(transform).joined(separator: "\n") + (trailingNewline ? "\n" : "")
        guard shouldChangeText(in: range, replacementString: out) else { return }
        replaceCharacters(in: range, with: out)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (out as NSString).length))
    }
}

// MARK: - line numbers

final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let tv = textView, let layout = tv.layoutManager, let container = tv.textContainer else { return }
        let s = tv.string as NSString
        let visible = tv.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]

        var lineNumber = 1
        if chars.location > 0 {
            s.substring(to: chars.location).forEach { if $0 == "\n" { lineNumber += 1 } }
        }
        func draw(_ n: Int, at y: CGFloat) {
            let label = NSAttributedString(string: String(n), attributes: attrs)
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.maxX - 8 - size.width, y: y + tv.textContainerInset.height - visible.minY + (ShellTextView.font.pointSize * 1.3 - size.height) / 2))
        }

        var pos = chars.location
        while pos < s.length, pos < NSMaxRange(chars) {
            let lineRange = s.lineRange(for: NSRange(location: pos, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(lineNumber, at: fragment.minY)
            lineNumber += 1
            pos = NSMaxRange(lineRange)
        }
        if s.length == 0 || (s.hasSuffix("\n") && pos >= s.length) {
            draw(lineNumber, at: layout.extraLineFragmentRect.minY)
        }
    }
}

// MARK: - highlighting

enum ShellTheme {
    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return hex(isDark ? dark : light)
        }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    // GitHub's light and dark code palettes.
    static let plain = NSColor.labelColor
    static let comment = dynamic(light: 0x6e7781, dark: 0x8b949e)
    static let string = dynamic(light: 0x0a3069, dark: 0xa5d6ff)
    static let keyword = dynamic(light: 0xcf222e, dark: 0xff7b72)
    static let command = dynamic(light: 0x8250df, dark: 0xd2a8ff)
    static let variable = dynamic(light: 0x953800, dark: 0xffa657)
    static let option = dynamic(light: 0x0550ae, dark: 0x79c0ff)
    static let op = dynamic(light: 0x57606a, dark: 0x8b949e)
}

enum ShellHighlighter {
    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
        "function", "select", "local", "export", "readonly", "return", "exit", "break", "continue", "!",
    ]
    private static let commandFollows: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!"]

    static func highlight(_ storage: NSTextStorage) {
        let s = storage.string as NSString
        let n = s.length
        storage.beginEditing()
        storage.setAttributes([.font: ShellTextView.font, .foregroundColor: ShellTheme.plain], range: NSRange(location: 0, length: n))
        func color(_ range: NSRange, _ c: NSColor) {
            guard range.length > 0, NSMaxRange(range) <= n else { return }
            storage.addAttribute(.foregroundColor, value: c, range: range)
        }

        var i = 0
        var expectCommand = true
        func ch(_ k: Int) -> Character { k < n ? Character(UnicodeScalar(s.character(at: k)) ?? " ") : "\0" }
        let wordBreak: Set<Character> = [" ", "\t", "\n", "|", "&", ";", "(", ")", "<", ">", "\"", "'", "$", "`"]

        /// `$NAME`, `${…}`, `$(…)`, `$?`… starting at `start`. Returns the end index.
        func variable(from start: Int) -> Int {
            var k = start + 1
            if ch(k) == "{" {
                while k < n, ch(k) != "}", ch(k) != "\n" { k += 1 }
                k = min(k + 1, n)
            } else if ch(k) == "(" {
                var depth = 0
                while k < n {
                    if ch(k) == "(" { depth += 1 } else if ch(k) == ")" { depth -= 1; if depth == 0 { k += 1; break } }
                    k += 1
                }
            } else if ch(k).isLetter || ch(k) == "_" {
                while k < n, ch(k).isLetter || ch(k).isNumber || ch(k) == "_" { k += 1 }
            } else if k < n, "?!@#*$0123456789-".contains(ch(k)) {
                k += 1
            }
            color(NSRange(location: start, length: k - start), ShellTheme.variable)
            return k
        }

        while i < n {
            let c = ch(i)
            if c == "#" && (i == 0 || " \t\n;|&(".contains(ch(i - 1))) {
                var k = i
                while k < n, ch(k) != "\n" { k += 1 }
                color(NSRange(location: i, length: k - i), ShellTheme.comment)
                i = k
            } else if c == "\n" {
                expectCommand = true
                i += 1
            } else if c == " " || c == "\t" {
                i += 1
            } else if c == "'" {
                var k = i + 1
                while k < n, ch(k) != "'" { k += 1 }
                k = min(k + 1, n)
                color(NSRange(location: i, length: k - i), ShellTheme.string)
                i = k
                expectCommand = false
            } else if c == "\"" {
                var k = i + 1
                var inner: [Int] = []
                while k < n, ch(k) != "\"" {
                    if ch(k) == "\\" { k += 2; continue }
                    if ch(k) == "$" { inner.append(k) }
                    k += 1
                }
                k = min(k + 1, n)
                color(NSRange(location: i, length: k - i), ShellTheme.string)
                for start in inner where start < k - 1 { _ = variable(from: start) }
                i = k
                expectCommand = false
            } else if c == "$" {
                if ch(i + 1) == "(" {
                    color(NSRange(location: i, length: 2), ShellTheme.op)
                    i += 2
                    expectCommand = true
                } else {
                    i = variable(from: i)
                    expectCommand = false
                }
            } else if c == "`" {
                color(NSRange(location: i, length: 1), ShellTheme.op)
                i += 1
                expectCommand = true
            } else if "|&;(){}<>".contains(c) {
                var k = i + 1
                while k < n, "|&;<>".contains(ch(k)), k - i < 3 { k += 1 }
                color(NSRange(location: i, length: k - i), ShellTheme.op)
                if "|&;({".contains(c) || c == "}" { expectCommand = true }
                i = k
            } else {
                var k = i
                while k < n, !wordBreak.contains(ch(k)) { k += 1 }
                let range = NSRange(location: i, length: k - i)
                let word = s.substring(with: range)
                if keywords.contains(word) {
                    color(range, ShellTheme.keyword)
                    expectCommand = commandFollows.contains(word) || word == "local" || word == "export" ? true : false
                    if word == "local" || word == "export" || word == "readonly" { expectCommand = false }
                } else if let eq = word.firstIndex(of: "="), expectCommand, isIdentifier(word[word.startIndex..<eq]) {
                    let nameLength = (String(word[word.startIndex..<eq]) as NSString).length
                    color(NSRange(location: i, length: nameLength), ShellTheme.variable)
                } else if word.hasSuffix("()") || (ch(k) == "(" && expectCommand) {
                    color(range, ShellTheme.command)
                    expectCommand = true
                } else if expectCommand {
                    color(range, ShellTheme.command)
                    expectCommand = false
                } else if word.hasPrefix("-") && word.count > 1 {
                    color(range, ShellTheme.option)
                }
                i = max(k, i + 1)
            }
        }
        storage.endEditing()
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.dropLast(text.hasSuffix("+") ? 1 : 0).allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
