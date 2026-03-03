import SwiftUI

// MARK: - Tag chip display

struct TagChip: View {
    let tag: String
    var onRemove: (() -> Void)? = nil
    var color: Color = .blue

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Tag input field with chip display

struct TagInputView: View {
    @Binding var tags: [String]
    var placeholder: String = "Добавить тег"
    var color: Color = .blue

    @State private var inputText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Existing tags
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            TagChip(tag: tag, onRemove: {
                                tags.removeAll { $0 == tag }
                            }, color: color)
                        }
                    }
                }
            }

            // Input field
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $inputText)
                    .focused($isFocused)
                    .font(.body)
                    .onSubmit { addTag() }
                    .onChange(of: inputText) { _, new in
                        if new.hasSuffix(" ") || new.hasSuffix(",") {
                            addTag()
                        }
                    }

                if !inputText.isEmpty {
                    Button(action: addTag) {
                        Image(systemName: "return")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func addTag() {
        let clean = inputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",#"))
        guard !clean.isEmpty, !tags.contains(clean) else {
            inputText = ""
            return
        }
        withAnimation(.spring(duration: 0.2)) {
            tags.append(clean)
        }
        inputText = ""
    }
}

// MARK: - Tag filter bar

struct TagFilterBar: View {
    let availableTags: [String]
    @Binding var selectedTag: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(tag: nil, label: "Все")

                ForEach(availableTags, id: \.self) { tag in
                    filterChip(tag: tag, label: "#\(tag)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func filterChip(tag: String?, label: String) -> some View {
        let isSelected = selectedTag == tag
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTag = (selectedTag == tag) ? nil : tag
            }
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
