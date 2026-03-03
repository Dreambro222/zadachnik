import SwiftUI

struct AISettingsView: View {
    @StateObject private var ai = AIManager.shared

    @State private var openAIKey     = KeychainHelper.load(KeychainKey.openAIAPIKey)     ?? ""
    @State private var claudeKey     = KeychainHelper.load(KeychainKey.claudeAPIKey)     ?? ""
    @State private var perplexityKey = KeychainHelper.load(KeychainKey.perplexityAPIKey) ?? ""
    @State private var saved = false

    var body: some View {
        Form {

            // MARK: - Provider picker
            Section {
                HStack(spacing: 8) {
                    ForEach(AIProvider.allCases) { provider in
                        providerChip(provider)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("Активный провайдер", systemImage: "brain.filled.head.profile")
            }

            // MARK: - OpenAI
            Section {
                SecureField("sk-...", text: $openAIKey)
                    .font(.system(.body, design: .monospaced))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Модель").font(.caption).foregroundStyle(.secondary)
                    ForEach(OpenAIModel.allCases) { model in
                        modelRow(
                            name: model.displayName,
                            desc: model.description,
                            isSelected: ai.selectedOpenAIModel == model,
                            isNew: [OpenAIModel.gpt52codex, .gpt52, .gpt52pro].contains(model)
                        ) {
                            ai.setOpenAIModel(model)
                            ai.setProvider(.openai)
                        }
                    }
                }
            } header: {
                Label("OpenAI", systemImage: "brain.filled.head.profile")
            } footer: {
                Link("Получить ключ → platform.openai.com/api-keys",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }

            // MARK: - Claude
            Section {
                SecureField("sk-ant-...", text: $claudeKey)
                    .font(.system(.body, design: .monospaced))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Модель").font(.caption).foregroundStyle(.secondary)
                    ForEach(ClaudeModel.allCases) { model in
                        modelRow(
                            name: model.displayName,
                            desc: model.description,
                            isSelected: ai.selectedClaudeModel == model,
                            isNew: true
                        ) {
                            ai.setClaudeModel(model)
                            ai.setProvider(.claude)
                        }
                    }
                }
            } header: {
                Label("Claude (Anthropic)", systemImage: "sparkles")
            } footer: {
                Link("Получить ключ → console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com")!)
                    .font(.caption)
            }

            // MARK: - Perplexity
            Section {
                SecureField("pplx-...", text: $perplexityKey)
                    .font(.system(.body, design: .monospaced))

                HStack {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sonar-pro").font(.subheadline).fontWeight(.medium)
                        Text("Поиск в интернете в реальном времени").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .padding(.vertical, 4)
            } header: {
                Label("Perplexity", systemImage: "magnifyingglass.circle.fill")
            } footer: {
                Link("Получить ключ → perplexity.ai/settings/api",
                     destination: URL(string: "https://www.perplexity.ai/settings/api")!)
                    .font(.caption)
            }

            // MARK: - Save
            Section {
                Button {
                    KeychainHelper.save(openAIKey,     for: KeychainKey.openAIAPIKey)
                    KeychainHelper.save(claudeKey,     for: KeychainKey.claudeAPIKey)
                    KeychainHelper.save(perplexityKey, for: KeychainKey.perplexityAPIKey)
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                } label: {
                    HStack {
                        Spacer()
                        Label(
                            saved ? "Сохранено!" : "Сохранить ключи",
                            systemImage: saved ? "checkmark.circle.fill" : "key.fill"
                        )
                        .fontWeight(.semibold)
                        .foregroundStyle(saved ? .green : .blue)
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("ИИ-настройки")
        .navigationInline()
    }

    // MARK: - Provider Chip

    private func providerChip(_ provider: AIProvider) -> some View {
        let isActive = ai.selectedProvider == provider
        return Button { ai.setProvider(provider) } label: {
            HStack(spacing: 5) {
                Image(systemName: provider.icon).font(.caption)
                Text(provider.shortName).font(.subheadline)
                    .fontWeight(isActive ? .bold : .regular)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                isActive ? Color(hex: provider.color) : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(isActive ? .white : .primary)
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: isActive)
    }

    // MARK: - Model Row

    private func modelRow(
        name: String,
        desc: String,
        isSelected: Bool,
        isNew: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.subheadline).fontWeight(isSelected ? .semibold : .regular)
                        if isNew {
                            Text("NEW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.blue, in: Capsule())
                        }
                    }
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
