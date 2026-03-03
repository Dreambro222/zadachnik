import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Block types

enum TextBlockType: String, Codable, CaseIterable {
    case paragraph  = "paragraph"
    case h1         = "h1"
    case h2         = "h2"
    case bullet     = "bullet"
    case numbered   = "numbered"
    case checklist  = "checklist"
    case quote      = "quote"
    case code       = "code"

    var icon: String {
        switch self {
        case .paragraph: return "text.alignleft"
        case .h1:        return "textformat.size.larger"
        case .h2:        return "textformat.size"
        case .bullet:    return "list.bullet"
        case .numbered:  return "list.number"
        case .checklist: return "checklist"
        case .quote:     return "text.quote"
        case .code:      return "chevron.left.forwardslash.chevron.right"
        }
    }

    var label: String {
        switch self {
        case .paragraph: return "Текст"
        case .h1:        return "Заголовок 1"
        case .h2:        return "Заголовок 2"
        case .bullet:    return "Маркированный список"
        case .numbered:  return "Нумерованный список"
        case .checklist: return "Чеклист"
        case .quote:     return "Цитата"
        case .code:      return "Код"
        }
    }
}

// MARK: - TextBlock model

struct TextBlock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var type: TextBlockType = .paragraph
    var text: String = ""
    var checked: Bool = false
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false

    static func empty(_ type: TextBlockType = .paragraph) -> TextBlock {
        TextBlock(
            id: UUID(),
            type: type,
            text: "",
            checked: false,
            isBold: false,
            isItalic: false,
            isUnderline: false
        )
    }
}

// MARK: - RichText codec

enum RichText {
    static func parse(_ raw: String) -> [TextBlock] {
        guard !raw.isEmpty else { return [.empty()] }
        if let data = raw.data(using: .utf8),
           let blocks = try? JSONDecoder().decode([TextBlock].self, from: data) {
            return blocks.isEmpty ? [.empty()] : blocks
        }
        // Plain text fallback — infer list/checklist types from prefixes.
        return raw.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let leading = String(line.prefix { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("✅ ") || trimmed.hasPrefix("☑ ") {
                var b = TextBlock.empty(.checklist)
                b.checked = true
                b.text = leading + String(trimmed.dropFirst(2))
                return b
            }
            if trimmed.hasPrefix("○ ") || trimmed.hasPrefix("☐ ") {
                var b = TextBlock.empty(.checklist)
                b.checked = false
                b.text = leading + String(trimmed.dropFirst(2))
                return b
            }
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                var b = TextBlock.empty(.checklist)
                b.checked = true
                b.text = leading + String(trimmed.dropFirst(6))
                return b
            }
            if trimmed.hasPrefix("- [ ] ") {
                var b = TextBlock.empty(.checklist)
                b.checked = false
                b.text = leading + String(trimmed.dropFirst(6))
                return b
            }
            if trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") {
                var b = TextBlock.empty(.bullet)
                b.text = leading + String(trimmed.dropFirst(2))
                return b
            }
            if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                var b = TextBlock.empty(.numbered)
                b.text = leading + String(trimmed[match.upperBound...])
                return b
            }
            var b = TextBlock.empty(.paragraph)
            b.text = line
            return b
        }
    }

    static func serialize(_ blocks: [TextBlock]) -> String {
        (try? String(data: JSONEncoder().encode(blocks), encoding: .utf8)) ?? ""
    }

    static func plainText(_ blocks: [TextBlock]) -> String {
        blocks.map { block in
            switch block.type {
            case .bullet:    return "\u{2022} \(block.text)"
            case .numbered:  return "\(block.text)"
            case .checklist: return "\(block.checked ? "✅" : "○") \(block.text)"
            case .quote:     return "\"\(block.text)\""
            case .code:      return "`\(block.text)`"
            case .h1:        return "# \(block.text)"
            case .h2:        return "## \(block.text)"
            case .paragraph: return block.text
            }
        }.joined(separator: "\n")
    }
}

// MARK: - RichTextEditor

struct RichTextEditor: View {
    @Binding var raw: String
    var placeholder: String = "Начните писать..."
    var minHeight: CGFloat = 120

    @State private var blocks: [TextBlock] = []
    @State private var focusedId: UUID? = nil
    @State private var isLoaded = false
#if os(macOS)
    @State private var isDropTargeted = false
#endif

    var body: some View {
#if os(macOS)
        macPlainEditor
#else
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach($blocks) { $block in
                    BlockRow(
                        block: $block,
                        isFocused: focusedId == block.id,
                        numberInList: numberedIndex(for: block),
                        onFocus: { focusedId = block.id },
                        onEnter: { handleEnter(after: block) },
                        onBackspaceOnEmpty: { handleBackspace(block: block) },
                        onApplyType: { applyType($0) },
                        onToggleBold: { toggleBold() },
                        onToggleItalic: { toggleItalic() },
                        onToggleUnderline: { toggleUnderline() },
                        onChange: { saveBlocks() }
                    )
                }

                // Tap-to-focus area below all blocks
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let last = blocks.last {
                            focusedId = last.id
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
#if os(macOS)
            keyboardShortcutsLayer
#endif
        }
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focusedId != nil ? Color.blue.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: focusedId)
        .onAppear {
            if !isLoaded {
                blocks = RichText.parse(raw)
                isLoaded = true
            }
        }
        .onChange(of: raw) { _, newVal in
            let current = RichText.serialize(blocks)
            if newVal != current {
                blocks = RichText.parse(newVal)
            }
        }
#endif
    }

#if os(macOS)
    private var macPlainEditor: some View {
        ZStack(alignment: .topLeading) {
            MacPlainTextEditor(text: macPlainBinding, minHeight: minHeight)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(minHeight: minHeight)

            if macPlainBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Color.blue.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: isDropTargeted ? 2 : 1)
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            Task { await importDroppedProviders(providers) }
            return true
        }
    }

    private var macPlainBinding: Binding<String> {
        Binding(
            get: {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("["),
                   let data = raw.data(using: .utf8),
                   (try? JSONDecoder().decode([TextBlock].self, from: data)) != nil {
                    return RichText.plainText(RichText.parse(raw))
                }
                return raw
            },
            set: { newVal in
                raw = newVal
            }
        )
    }

    private func importDroppedProviders(_ providers: [NSItemProvider]) async {
        var lines: [String] = []
        let dir = attachmentsDirectory()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadFileURL(from: provider) {
                let saved = copyFileToAttachments(url: url, dir: dir)
                lines.append("📎 \(saved.lastPathComponent)")
                continue
            }

            if provider.canLoadObject(ofClass: NSImage.self),
               let image = await loadImage(from: provider),
               let saved = saveImageToAttachments(image: image, dir: dir) {
                lines.append("🖼 \(saved.lastPathComponent)")
            }
        }

        guard !lines.isEmpty else { return }
        await MainActor.run {
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                raw = lines.joined(separator: "\n")
            } else {
                raw += "\n" + lines.joined(separator: "\n")
            }
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else if let url = item as? URL {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func loadImage(from provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { cont in
            provider.loadObject(ofClass: NSImage.self) { obj, _ in
                cont.resume(returning: obj as? NSImage)
            }
        }
    }

    private func attachmentsDirectory() -> URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func copyFileToAttachments(url: URL, dir: URL) -> URL {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let destName = UUID().uuidString + "_" + url.lastPathComponent
        let destURL = dir.appendingPathComponent(destName)
        try? FileManager.default.copyItem(at: url, to: destURL)
        return destURL
    }

    private func saveImageToAttachments(image: NSImage, dir: URL) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let destName = UUID().uuidString + "_image.png"
        let destURL = dir.appendingPathComponent(destName)
        do {
            try png.write(to: destURL)
            return destURL
        } catch {
            return nil
        }
    }
#endif

    // MARK: - Actions

    private func applyType(_ type: TextBlockType) {
        if let id = focusedId,
           let idx = blocks.firstIndex(where: { $0.id == id }) {
            blocks[idx].type = type
        } else {
            var b = TextBlock.empty(type)
            blocks.append(b)
            focusedId = b.id
        }
        saveBlocks()
    }

    private func toggleBold() {
        guard let id = focusedId,
              let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].isBold.toggle()
        saveBlocks()
    }

    private func toggleItalic() {
        guard let id = focusedId,
              let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].isItalic.toggle()
        saveBlocks()
    }

    private func toggleUnderline() {
        guard let id = focusedId,
              let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[idx].isUnderline.toggle()
        saveBlocks()
    }

    private func handleEnter(after block: TextBlock) {
        guard let idx = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let newType: TextBlockType
        switch block.type {
        case .bullet, .numbered, .checklist:
            newType = block.text.isEmpty ? .paragraph : block.type
        default:
            newType = .paragraph
        }
        let newBlock = TextBlock.empty(newType)
        blocks.insert(newBlock, at: idx + 1)
        focusedId = newBlock.id
        saveBlocks()
    }

    private func handleBackspace(block: TextBlock) {
        guard blocks.count > 1,
              let idx = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        if block.type != .paragraph {
            blocks[idx].type = .paragraph
            saveBlocks()
            return
        }
        let prevIdx = max(0, idx - 1)
        let prevId = blocks[prevIdx].id
        blocks.remove(at: idx)
        focusedId = prevId
        saveBlocks()
    }

    private func saveBlocks() {
        raw = RichText.serialize(blocks)
    }

    private func numberedIndex(for block: TextBlock) -> Int {
        guard block.type == .numbered else { return 0 }
        var count = 0
        for b in blocks {
            if b.type == .numbered {
                count += 1
                if b.id == block.id { return count }
            } else {
                count = 0
            }
        }
        return 1
    }

#if os(macOS)
    private var keyboardShortcutsLayer: some View {
        HStack(spacing: 0) {
            Button("") { toggleBold() }.keyboardShortcut("b", modifiers: [.command])
            Button("") { toggleItalic() }.keyboardShortcut("i", modifiers: [.command])
            Button("") { toggleUnderline() }.keyboardShortcut("u", modifiers: [.command])
            Button("") { applyType(.bullet) }.keyboardShortcut("8", modifiers: [.command, .shift])
            Button("") { applyType(.numbered) }.keyboardShortcut("7", modifiers: [.command, .shift])
            Button("") { applyType(.checklist) }.keyboardShortcut("9", modifiers: [.command, .shift])
            Button("") { applyType(.h1) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("") { applyType(.h2) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("") { applyType(.paragraph) }.keyboardShortcut("0", modifiers: [.command, .option])
        }
        .labelsHidden()
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
#endif
}

// MARK: - BlockRow
// Использует TextEditor (полностью многострочный) вместо TextField

private struct BlockRow: View {
    @Binding var block: TextBlock
    let isFocused: Bool
    let numberInList: Int
    let onFocus: () -> Void
    let onEnter: () -> Void
    let onBackspaceOnEmpty: () -> Void
    let onApplyType: (TextBlockType) -> Void
    let onToggleBold: () -> Void
    let onToggleItalic: () -> Void
    let onToggleUnderline: () -> Void
    let onChange: () -> Void

    @FocusState private var focused: Bool
    @State private var textHeight: CGFloat = 22

    private let lineHeight: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            gutter
            editor
        }
        .padding(.vertical, 2)
        .onChange(of: focused) { _, val in if val { onFocus() } }
        .onAppear { if isFocused { focused = true } }
        .onChange(of: isFocused) { _, val in if val { focused = true } }
        .contextMenu {
            Menu("Тип блока") {
                ForEach(TextBlockType.allCases, id: \.self) { type in
                    Button {
                        onApplyType(type)
                    } label: {
                        Label(type.label, systemImage: type.icon)
                    }
                }
            }
            Divider()
            Button {
                onToggleBold()
            } label: {
                Label("Жирный", systemImage: block.isBold ? "checkmark.circle.fill" : "circle")
            }
            Button {
                onToggleItalic()
            } label: {
                Label("Курсив", systemImage: block.isItalic ? "checkmark.circle.fill" : "circle")
            }
            Button {
                onToggleUnderline()
            } label: {
                Label("Подчеркнутый", systemImage: block.isUnderline ? "checkmark.circle.fill" : "circle")
            }
        }
    }

    // MARK: Gutter

    @ViewBuilder
    private var gutter: some View {
        switch block.type {
        case .checklist:
            Button {
                block.checked.toggle()
                onChange()
            } label: {
                ChecklistCircleIcon(isChecked: block.checked, size: 20)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

        case .bullet:
            Circle()
                .fill(Color.secondary.opacity(0.8))
                .frame(width: 5, height: 5)
                .padding(.top, 8)

        case .numbered:
            Text("\(numberInList).")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
                .padding(.top, 1)

        case .quote:
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue.opacity(0.6))
                .frame(width: 3, height: textHeight)

        case .code:
            EmptyView()

        default:
            EmptyView()
        }
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            // Невидимый текст для авторасчёта высоты
            Text(block.text.isEmpty ? " " : block.text)
                .font(editorFont)
                .foregroundStyle(.clear)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear { textHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in textHeight = h }
                    }
                )

            // Реальный редактор
#if os(macOS)
            MacBlockTextEditor(
                text: editableText,
                font: nsEditorFont,
                textColor: nsTextColor,
                isFocused: isFocused,
                onFocus: onFocus,
                onEnter: onEnter,
                onBackspaceOnEmpty: onBackspaceOnEmpty,
                onChange: onChange
            )
            .frame(height: max(textHeight, lineHeight))
            .background(block.type == .code ? Color.secondary.opacity(0.08) : Color.clear)
#else
            TextEditor(text: editableText)
                .focused($focused)
                .font(editorFont)
                .foregroundStyle(textColor)
                .fontWeight(block.isBold ? .bold : .regular)
                .italic(block.isItalic)
                .underline(block.isUnderline)
                .scrollContentBackground(.hidden)
                .background(block.type == .code ? Color.secondary.opacity(0.08) : Color.clear)
                .frame(height: max(textHeight, lineHeight))
                .padding(.horizontal, 0)
                .padding(.vertical, 0)
#endif
        }
        .strikethrough(block.type == .checklist && block.checked, color: .secondary)
    }

    // Прокси-binding с перехватом Enter и backspace
    private var editableText: Binding<String> {
        Binding(
            get: { block.text },
            set: { newVal in
                // Enter → новый блок
                if newVal.hasSuffix("\n") {
                    block.text = String(newVal.dropLast())
                    onChange()
                    onEnter()
                    return
                }
                // Backspace на пустом блоке
                if newVal.isEmpty && !block.text.isEmpty {
                    block.text = newVal
                    onChange()
                    return
                }
                if newVal.isEmpty && block.text.isEmpty {
                    onBackspaceOnEmpty()
                    return
                }
                block.text = newVal
                onChange()
            }
        )
    }

    private var editorFont: Font {
        switch block.type {
        case .h1:    return .title2.weight(.bold)
        case .h2:    return .title3.weight(.semibold)
        case .code:  return .system(.body, design: .monospaced)
        case .quote: return .body.italic()
        default:     return .body
        }
    }

    private var textColor: Color {
        if block.type == .checklist && block.checked { return .secondary }
        if block.type == .quote { return .secondary }
        return .primary
    }

#if os(macOS)
    private var nsEditorFont: NSFont {
        switch block.type {
        case .h1:    return NSFont.systemFont(ofSize: 22, weight: .bold)
        case .h2:    return NSFont.systemFont(ofSize: 19, weight: .semibold)
        case .code:  return NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        default:     return NSFont.systemFont(ofSize: 17, weight: .regular)
        }
    }

    private var nsTextColor: NSColor {
        if block.type == .checklist && block.checked { return .secondaryLabelColor }
        if block.type == .quote { return .secondaryLabelColor }
        return .labelColor
    }
#endif
}

#if os(macOS)
private struct MacBlockTextEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    let isFocused: Bool
    let onFocus: () -> Void
    let onEnter: () -> Void
    let onBackspaceOnEmpty: () -> Void
    let onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder

        let tv = BlockTextView()
        tv.delegate = context.coordinator
        tv.onEnter = onEnter
        tv.onBackspaceOnEmpty = onBackspaceOnEmpty
        tv.onFocus = onFocus
        tv.isRichText = false
        tv.isEditable = true
        tv.backgroundColor = .clear
        tv.font = font
        tv.textColor = textColor
        tv.string = text
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        context.coordinator.textView = tv

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        tv.font = font
        tv.textColor = textColor
        tv.onEnter = onEnter
        tv.onBackspaceOnEmpty = onBackspaceOnEmpty
        tv.onFocus = onFocus

        if tv.string != text {
            tv.string = text
        }

        if isFocused, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacBlockTextEditor
        weak var textView: BlockTextView?
        init(_ parent: MacBlockTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            parent.onChange()
        }
    }
}

private final class BlockTextView: NSTextView {
    var onEnter: (() -> Void)?
    var onBackspaceOnEmpty: (() -> Void)?
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return
            onEnter?()
            return
        case 51: // Backspace
            if string.isEmpty {
                onBackspaceOnEmpty?()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}
#endif

// MARK: - macOS plain editor with native list continuation
#if os(macOS)
private struct MacPlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let minHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = TaskPlainTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.backgroundColor = .clear
        tv.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 2, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: minHeight)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text

        context.coordinator.textView = tv
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {
            tv.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacPlainTextEditor
        weak var textView: TaskPlainTextView?

        init(_ parent: MacPlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
        }
    }
}

final class TaskPlainTextView: NSTextView {
    private static weak var focusedEditor: TaskPlainTextView?

    static func insertAtCursor(_ text: String) -> Bool {
        guard let editor = focusedEditor else { return false }
        editor.insertAtCurrentSelection(text)
        return true
    }

    static func insertListPrefixAtCursor(_ prefix: String) -> Bool {
        guard let editor = focusedEditor else { return false }
        editor.insertListPrefixOnNewLine(prefix)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { Self.focusedEditor = self }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        // Keep last focused editor reference so toolbar clicks
        // can still insert at the previous caret position.
        return super.resignFirstResponder()
    }

    deinit {
        if Self.focusedEditor === self {
            Self.focusedEditor = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleChecklistAtClick(point: point) {
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), shouldHandleContinuation(event),
           handleListContinuationOnReturn() {
            return
        }
        super.keyDown(with: event)
    }

    private func shouldHandleContinuation(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !mods.contains(.command) && !mods.contains(.option) && !mods.contains(.control)
    }

    private func handleListContinuationOnReturn() -> Bool {
        guard let storage = textStorage else { return false }
        normalizeChecklistPrefixes(in: storage)
        let selection = selectedRange()
        let source = storage.string as NSString
        let lineRange = source.lineRange(for: selection)
        let line = source.substring(with: lineRange)
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        let content = String(line.dropFirst(leading.count))

        guard let prefix = continuationPrefix(for: content) else {
            return false
        }

        let stripped = stripListPrefix(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty {
            storage.replaceCharacters(in: lineRange, with: leading)
            setSelectedRange(NSRange(location: lineRange.location + (leading as NSString).length, length: 0))
            didChangeText()
            return true
        }

        let insertion = "\n" + leading + prefix
        storage.replaceCharacters(in: selection, with: insertion)
        setSelectedRange(NSRange(location: selection.location + (insertion as NSString).length, length: 0))
        didChangeText()
        return true
    }

    private func continuationPrefix(for line: String) -> String? {
        if line.hasPrefix("○ ") || line.hasPrefix("✅ ") || line.hasPrefix("☐ ") || line.hasPrefix("☑ ") { return "○ " }
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") { return "○ " }
        if line.hasPrefix("• ") { return "• " }
        if line.hasPrefix("- ") { return "- " }
        if let match = line.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
            let rawPrefix = String(line[match])
            let number = Int(rawPrefix.components(separatedBy: ".").first ?? "1") ?? 1
            return "\(number + 1). "
        }
        return nil
    }

    private func stripListPrefix(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("○ ") || trimmed.hasPrefix("✅ ") || trimmed.hasPrefix("☐ ") || trimmed.hasPrefix("☑ ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") {
            return String(trimmed.dropFirst(2))
        }
        if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            return String(trimmed[match.upperBound...])
        }
        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
            return String(trimmed.dropFirst(6))
        }
        return trimmed
    }

    private func toggleChecklistAtClick(point: NSPoint) -> Bool {
        guard let storage = textStorage,
              let container = textContainer,
              let layout = layoutManager else { return false }

        let glyphIndex = layout.glyphIndex(for: point, in: container)
        let charIndex = layout.characterIndexForGlyph(at: glyphIndex)
        let source = storage.string as NSString
        guard charIndex < source.length else { return false }

        let lineRange = source.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = source.substring(with: lineRange)
        let leadingCount = line.prefix { $0 == " " || $0 == "\t" }.count
        let contentStart = lineRange.location + leadingCount

        // Toggle only when user clicks near checkbox marker.
        guard charIndex <= contentStart + 2 else { return false }

        if line.dropFirst(leadingCount).hasPrefix("○ ") || line.dropFirst(leadingCount).hasPrefix("☐ ") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 2), with: "✅ ")
            didChangeText()
            return true
        }
        if line.dropFirst(leadingCount).hasPrefix("✅ ") || line.dropFirst(leadingCount).hasPrefix("☑ ") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 2), with: "○ ")
            didChangeText()
            return true
        }
        if line.dropFirst(leadingCount).hasPrefix("- [ ] ") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 6), with: "✅ ")
            didChangeText()
            return true
        }
        if line.dropFirst(leadingCount).hasPrefix("- [x] ") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 6), with: "○ ")
            didChangeText()
            return true
        }
        if line.dropFirst(leadingCount).hasPrefix("[ ]") || line.dropFirst(leadingCount).hasPrefix("[]") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: line.dropFirst(leadingCount).hasPrefix("[ ]") ? 3 : 2), with: "✅ ")
            didChangeText()
            return true
        }
        if line.dropFirst(leadingCount).hasPrefix("[x]") || line.dropFirst(leadingCount).hasPrefix("[X]") || line.dropFirst(leadingCount).hasPrefix("[✓]") {
            storage.replaceCharacters(in: NSRange(location: contentStart, length: 3), with: "○ ")
            didChangeText()
            return true
        }
        return false
    }

    private func insertAtCurrentSelection(_ inserted: String) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        storage.replaceCharacters(in: selection, with: inserted)
        setSelectedRange(NSRange(location: selection.location + (inserted as NSString).length, length: 0))
        didChangeText()
    }

    private func insertListPrefixOnNewLine(_ prefix: String) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        let source = storage.string as NSString
        let safeLocation = max(0, min(selection.location, source.length))

        let needsLeadingNewline: Bool
        if safeLocation == 0 {
            needsLeadingNewline = false
        } else {
            let prev = source.character(at: safeLocation - 1)
            needsLeadingNewline = prev != 10 && prev != 13
        }

        let insertion = (needsLeadingNewline ? "\n" : "") + prefix
        storage.replaceCharacters(in: selection, with: insertion)
        setSelectedRange(NSRange(location: safeLocation + (insertion as NSString).length, length: 0))
        didChangeText()
    }

    override func didChangeText() {
        super.didChangeText()
        guard let storage = textStorage else { return }
        let changed = normalizeChecklistPrefixes(in: storage)
        if changed {
            // Keep delegate/model in sync after normalization pass.
            super.didChangeText()
        }
    }

    @discardableResult
    private func normalizeChecklistPrefixes(in storage: NSTextStorage) -> Bool {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return false }

        var changed = false
        storage.beginEditing()
        defer { storage.endEditing() }

        let lines = storage.string.components(separatedBy: .newlines)
        var location = 0
        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: location, length: nsLine.length)
            let leadingCount = line.prefix { $0 == " " || $0 == "\t" }.count
            let content = String(line.dropFirst(leadingCount))
            let leading = String(line.prefix(leadingCount))
            var normalized: String? = nil

            if content.hasPrefix("[ ] ") || content.hasPrefix("[] ") {
                normalized = leading + "○ " + String(content.dropFirst(content.hasPrefix("[ ] ") ? 4 : 3))
            } else if content == "[ ]" || content == "[]" {
                normalized = leading + "○ "
            } else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") || content.hasPrefix("[✓] ") {
                normalized = leading + "✅ " + String(content.dropFirst(4))
            } else if content == "[x]" || content == "[X]" || content == "[✓]" {
                normalized = leading + "✅ "
            } else if content.hasPrefix("- [ ] ") {
                normalized = leading + "○ " + String(content.dropFirst(6))
            } else if content.hasPrefix("- [x] ") || content.hasPrefix("- [X] ") {
                normalized = leading + "✅ " + String(content.dropFirst(6))
            }

            if let normalized, normalized != line {
                storage.replaceCharacters(in: range, with: normalized)
                changed = true
                location += (normalized as NSString).length + 1
            } else {
                location += nsLine.length + 1
            }
        }
        return changed
    }
}
#endif

// MARK: - RichTextPreview

struct RichTextPreview: View {
    let raw: String
    var lineLimit: Int = 3
    var font: Font = .body

    private var blocks: [TextBlock] { RichText.parse(raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(blocks.prefix(lineLimit)) { block in
                blockPreview(block)
            }
            if blocks.count > lineLimit {
                Text("…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func blockPreview(_ block: TextBlock) -> some View {
        HStack(alignment: .top, spacing: 4) {
            switch block.type {
            case .bullet:
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 5, height: 5)
                    .padding(.top, 6)
            case .numbered:
                Text("\u{2022}")
                    .font(font)
                    .foregroundStyle(.secondary)
            case .checklist:
                ChecklistCircleIcon(isChecked: block.checked, size: 14)
                    .padding(.top, 2)
            case .quote:
                Rectangle()
                    .fill(Color.blue.opacity(0.5))
                    .frame(width: 2)
            default:
                EmptyView()
            }

            Text(block.text.isEmpty ? " " : block.text)
                .font(previewFont(block))
                .foregroundStyle(previewColor(block))
                .fontWeight(block.isBold ? .bold : .regular)
                .italic(block.isItalic)
                .underline(block.isUnderline)
                .lineLimit(1)
                .strikethrough(block.type == .checklist && block.checked)
        }
    }

    private func previewFont(_ block: TextBlock) -> Font {
        switch block.type {
        case .h1:   return .subheadline.weight(.bold)
        case .h2:   return .subheadline.weight(.semibold)
        case .code: return .caption.monospaced()
        default:    return font
        }
    }

    private func previewColor(_ block: TextBlock) -> Color {
        if block.type == .checklist && block.checked { return .secondary }
        if block.type == .quote { return .secondary }
        return .primary
    }
}

private struct ChecklistCircleIcon: View {
    let isChecked: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            if isChecked {
                Circle()
                    .fill(Color(red: 0.96, green: 0.76, blue: 0.14))
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(Color.black.opacity(0.78))
            } else {
                Circle()
                    .stroke(Color.secondary.opacity(0.68), lineWidth: max(1.45, size * 0.085))
            }
        }
        .frame(width: size, height: size)
    }
}
