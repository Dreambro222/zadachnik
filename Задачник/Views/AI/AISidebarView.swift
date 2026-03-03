import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Context passed from parent view

struct AIContext {
    var screenName: String = ""     // e.g. "Задачи проекта «Маркетинг»"
    var objectDescription: String = ""  // serialised current object

    var fullDescription: String {
        var parts: [String] = []
        if !screenName.isEmpty { parts.append("Экран: \(screenName)") }
        if !objectDescription.isEmpty { parts.append(objectDescription) }
        return parts.joined(separator: "\n")
    }

    var isEmpty: Bool { screenName.isEmpty && objectDescription.isEmpty }
}

// MARK: - Chat item (message OR tool call)

enum ChatItem: Identifiable {
    case message(ChatMessage)
    case toolCall(AIToolCall)

    var id: String {
        switch self {
        case .message(let m):  return m.id.uuidString
        case .toolCall(let t): return t.id.uuidString
        }
    }
}

// MARK: - AISidebarView

struct AISidebarView: View {
    @Environment(\.modelContext) private var environmentContext
    @StateObject private var ai = AIManager.shared

    // Context injected by parent (current screen/object)
    var aiContext: AIContext = AIContext()
    /// Explicit modelContext override — pass from parent when @Environment may not propagate (e.g. HSplitView on macOS)
    var explicitModelContext: ModelContext? = nil

    @State private var messages: [ChatMessage] = []
    @State private var chatItems: [ChatItem] = []
    @State private var inputText = ""
    @State private var pendingImages: [AttachedImage] = []
    @State private var showImagePicker = false
    @State private var isDropTargeted = false

    private var modelContext: ModelContext {
        explicitModelContext ?? environmentContext
    }

    private var activeModelName: String {
        switch ai.selectedProvider {
        case .claude:     return ai.selectedClaudeModel.displayName
        case .openai:     return ai.selectedOpenAIModel.displayName
        case .perplexity: return "Sonar Pro"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            messageList

            if let error = ai.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }

            Divider()

            inputBar
        }
        .background(Color.groupedBackground)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                Text("ИИ-помощник")
                    .font(.headline)

                Text("·")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(activeModelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !aiContext.isEmpty {
                    Text("· \(aiContext.screenName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                providerPicker
                Spacer(minLength: 0)
                modelPicker
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var modelPicker: some View {
        Menu {
            switch ai.selectedProvider {
            case .openai:
                ForEach(OpenAIModel.allCases) { model in
                    Button {
                        ai.setOpenAIModel(model)
                    } label: {
                        HStack {
                            Text(model.displayName)
                            if ai.selectedOpenAIModel == model {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            case .claude:
                ForEach(ClaudeModel.allCases) { model in
                    Button {
                        ai.setClaudeModel(model)
                    } label: {
                        HStack {
                            Text(model.displayName)
                            if ai.selectedClaudeModel == model {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            case .perplexity:
                Text("Perplexity использует Sonar Pro")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                Text("LLM")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(activeModelName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .help("Выбрать LLM модель")
    }

    // MARK: - Provider Picker

    private var providerPicker: some View {
        HStack(spacing: 4) {
            ForEach(AIProvider.allCases) { provider in
                let isActive = ai.selectedProvider == provider
                Button {
                    withAnimation(.spring(duration: 0.2)) {
                        ai.setProvider(provider)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: provider.icon)
                            .font(.system(size: 10))
                        Text(provider.shortName)
                            .font(.caption)
                            .fontWeight(isActive ? .bold : .regular)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isActive ? Color(hex: provider.color) : Color.secondary.opacity(0.12),
                        in: Capsule()
                    )
                    .foregroundStyle(isActive ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }

            // Clear chat
            if !chatItems.isEmpty {
                Button {
                    withAnimation {
                        messages.removeAll()
                        chatItems.removeAll()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if chatItems.isEmpty {
                        emptyPrompts
                    }
                    ForEach(chatItems) { item in
                        switch item {
                        case .message(let msg):
                            ChatBubbleView(message: msg)
                                .id(item.id)
                        case .toolCall(let call):
                            ToolCallBubble(toolCall: call)
                                .id(item.id)
                        }
                    }
                    if ai.isLoading {
                        loadingBubble
                    }
                }
                .padding(12)
            }
            .onChange(of: chatItems.count) { _, _ in
                if let last = chatItems.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: ai.isLoading) { _, loading in
                if loading, let last = chatItems.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Empty prompts

    private var emptyPrompts: some View {
        VStack(spacing: 12) {
            Image(systemName: ai.selectedProvider.supportsTools ? "sparkles" : "magnifyingglass.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue.gradient)
                .padding(.top, 32)

            Text("Что хотите сделать?")
                .font(.subheadline)
                .fontWeight(.semibold)

            if ai.selectedProvider.supportsTools {
                VStack(spacing: 8) {
                    promptButton("Что у меня сегодня?")
                    promptButton("Создай задачу: ")
                    promptButton("Покажи просроченные задачи")
                    promptButton("Создай заметку: ")
                    promptButton("Добавь в календарь встречу завтра в 10:00")
                }
            } else {
                VStack(spacing: 8) {
                    promptButton("Найди информацию в интернете")
                    promptButton("Объясни концепцию")
                }
                Text("Perplexity работает в режиме поиска без доступа к вашим данным")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func promptButton(_ text: String) -> some View {
        Button {
            inputText = text
            if !text.hasSuffix(": ") && !text.hasSuffix(" ") {
                send()
            }
        } label: {
            Text(text)
                .font(.caption)
                .foregroundStyle(.blue)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading

    private var loadingBubble: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.5)
                        .animation(
                            .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2),
                            value: ai.isLoading
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))

            Button {
                ai.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if !pendingImages.isEmpty {
                imagePreviews
                Divider()
            }
            inputRow
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(isDropTargeted ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 2)
        )
    }

    private var imagePreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { img in
                    imageThumb(img)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.secondary.opacity(0.06))
    }

    private func imageThumb(_ img: AttachedImage) -> some View {
        ZStack(alignment: .topTrailing) {
            #if os(macOS)
            Group {
                if let ns = NSImage(data: img.previewData) {
                    Image(nsImage: ns).resizable().scaledToFill()
                } else {
                    Color.secondary
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            #else
            Group {
                if let ui = UIImage(data: img.previewData) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    Color.secondary
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            #endif
            Button {
                pendingImages.removeAll { $0.id == img.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
    }

    // Rough token estimate: ~4 chars per token
    private var estimatedTokens: Int { inputText.count / 4 }
    private var isLongMessage: Bool { estimatedTokens > 1500 }

    private var inputRow: some View {
        VStack(spacing: 0) {
            // Warning for very long messages
            if isLongMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Большой текст (~\(estimatedTokens) токенов). ИИ обработает, но может быть медленно.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Разбить на части") {
                        splitAndSend()
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }

            HStack(alignment: .bottom, spacing: 8) {
                attachButton

                TextField("Спросить ИИ...", text: $inputText, axis: .vertical)
                    .lineLimit(1...8)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    .onSubmit { send() }

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.blue : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend || ai.isLoading)
            }
            .padding(12)
        }
    }

    // Split large text into ~800-token chunks and send as separate messages
    private func splitAndSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let chunkSize = 3200  // ~800 tokens
        var chunks: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[idx..<end]))
            idx = end
        }

        guard chunks.count > 1 else { send(); return }

        // Replace input with first chunk + instruction, then send
        let total = chunks.count
        inputText = "Текст разбит на \(total) части. Часть 1/\(total) — прими и подтверди получение:\n\n\(chunks[0])"
        send()

        // Queue remaining chunks as follow-up user messages (they'll appear after reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for i in 1..<chunks.count {
                let chunkMsg = ChatMessage(role: .user,
                    text: "Часть \(i+1)/\(total):\n\n\(chunks[i])\(i == chunks.count-1 ? "\n\nТеперь разбери всё по задачам и проектам." : "")")
                messages.append(chunkMsg)
                chatItems.append(.message(chunkMsg))
            }
        }
    }

    private var attachButton: some View {
        Button {
            showImagePicker = true
        } label: {
            Image(systemName: pendingImages.isEmpty ? "photo.badge.plus" : "photo.badge.plus.fill")
                .font(.title3)
                .foregroundStyle(pendingImages.isEmpty ? Color.secondary : Color.blue)
        }
        .buttonStyle(.plain)
        .help("Прикрепить фото / скриншот (или перетащи в чат)")
        #if os(macOS)
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.image, .png, .jpeg, .heic, .tiff, .bmp, .gif],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { if let img = attachedImage(from: url) { pendingImages.append(img) } }
        }
        #endif
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    // MARK: - Image helpers

    private func attachedImage(from url: URL) -> AttachedImage? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return makeAttachedImage(data: data, url: url)
    }

    private func makeAttachedImage(data: Data, url: URL? = nil) -> AttachedImage? {
        #if os(macOS)
        guard let src = NSImage(data: data) else { return nil }
        // Downscale to max 1024px for API efficiency
        let maxDim: CGFloat = 1024
        let size = src.size
        let scale = min(maxDim / size.width, maxDim / size.height, 1.0)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let scaled = NSImage(size: newSize)
        scaled.lockFocus()
        src.draw(in: NSRect(origin: .zero, size: newSize))
        scaled.unlockFocus()
        guard let tiff = scaled.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        // Small preview (64x64)
        let prevScale = min(64 / size.width, 64 / size.height, 1.0)
        let prevSize  = NSSize(width: size.width * prevScale, height: size.height * prevScale)
        let prevImg   = NSImage(size: prevSize)
        prevImg.lockFocus(); src.draw(in: NSRect(origin: .zero, size: prevSize)); prevImg.unlockFocus()
        let prevData  = (NSBitmapImageRep(data: prevImg.tiffRepresentation ?? Data())?
            .representation(using: .jpeg, properties: [:]) ?? jpeg)
        return AttachedImage(base64: jpeg.base64EncodedString(), mimeType: "image/jpeg", previewData: prevData)
        #else
        guard let src = UIImage(data: data) else { return nil }
        let maxDim: CGFloat = 1024
        let scale = min(maxDim / src.size.width, maxDim / src.size.height, 1.0)
        let newSize = CGSize(width: src.size.width * scale, height: src.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaled = renderer.jpegData(withCompressionQuality: 0.85) { _ in
            src.draw(in: CGRect(origin: .zero, size: newSize))
        }
        let prevRenderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let prevData = prevRenderer.jpegData(withCompressionQuality: 0.8) { _ in
            src.draw(in: CGRect(origin: .zero, size: CGSize(width: 64, height: 64)))
        }
        return AttachedImage(base64: scaled.base64EncodedString(), mimeType: "image/jpeg", previewData: prevData)
        #endif
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let img = makeAttachedImage(data: data) else { return }
                    DispatchQueue.main.async { pendingImages.append(img) }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let urlData = item as? Data,
                          let url = URL(dataRepresentation: urlData, relativeTo: nil),
                          let img = attachedImage(from: url) else { return }
                    DispatchQueue.main.async { pendingImages.append(img) }
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: - Send

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        let imgs = pendingImages
        inputText = ""
        pendingImages = []

        var userMsg = ChatMessage(role: .user, text: text)
        userMsg.images = imgs
        messages.append(userMsg)
        chatItems.append(.message(userMsg))

        let contextText = aiContext.isEmpty ? nil : aiContext.fullDescription
        let executor = ai.selectedProvider.supportsTools
            ? AIToolExecutor(modelContext: modelContext)
            : nil

        let task = Task {
            let result = await ai.chat(
                messages: messages,
                context: contextText,
                executor: executor
            )

            guard !Task.isCancelled else { return }

            // Show tool calls inline
            for toolCall in result.toolCalls {
                chatItems.append(.toolCall(toolCall))
            }

            if let responseText = result.text {
                let assistantMsg = ChatMessage(role: .assistant, text: responseText)
                messages.append(assistantMsg)
                chatItems.append(.message(assistantMsg))
            }
        }
        ai.currentTask = task
    }
}

// MARK: - Chat Bubble

struct ChatBubbleView: View {
    let message: ChatMessage

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 32) }

            if !isUser {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .frame(width: 24, height: 24)
                    .background(.blue.opacity(0.1), in: Circle())
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // Attached images grid
                if !message.images.isEmpty {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(80), spacing: 4), count: min(message.images.count, 3)),
                        spacing: 4
                    ) {
                        ForEach(message.images) { img in
                            #if os(iOS)
                            if let uiImage = UIImage(data: img.previewData) {
                                Image(uiImage: uiImage)
                                    .resizable().scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            #else
                            if let nsImage = NSImage(data: img.previewData) {
                                Image(nsImage: nsImage)
                                    .resizable().scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            #endif
                        }
                    }
                }

                // Text bubble
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(isUser ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            isUser ? Color.blue : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .textSelection(.enabled)
                }
            }

            if !isUser { Spacer(minLength: 32) }
        }
    }
}

// MARK: - Tool Call Bubble

struct ToolCallBubble: View {
    let toolCall: AIToolCall
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: toolCall.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(toolCall.isError ? .orange : .green)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(toolCall.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(toolCall.result)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
