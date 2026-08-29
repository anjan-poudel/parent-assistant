import SwiftUI

struct ContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if coordinator.isInitialized {
                    Label("Assistant Ready", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.headline)
                } else {
                    ProgressView("Starting assistant...")
                }

                voiceStatusRow
                ModelDownloadSection(
                    service: coordinator.modelDownloadService,
                    visibleIds: coordinator.requiredModelIds
                )

                Text("Tap the button to talk. Medication reminders can auto-activate listening.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: { coordinator.simulateWakeWordDetection() }) {
                    Label("Talk to Assistant", systemImage: "waveform")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(10)
                }

                if let err = coordinator.voiceError {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let transcript = coordinator.lastTranscript {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last transcript")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(transcript)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(10)
                }
            }
            .padding()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("Elderly AI Assistant")
                .font(.title)
                .fontWeight(.bold)
            Text("Nepali-first voice helper")
                .font(.body)
                .foregroundColor(.secondary)
        }
    }

    private var voiceStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)
            Text(indicatorLabel)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var indicatorColor: Color {
        switch coordinator.voiceState {
        case .idle:              return .green
        case .capturingCommand:  return .orange
        case .processing:        return .yellow
        case .routing:           return .yellow
        case .error:             return .red
        case .stopped:           return .gray
        }
    }

    private var indicatorLabel: String {
        switch coordinator.voiceState {
        case .idle:              return "Listening for wake word"
        case .capturingCommand:  return "Listening for your command…"
        case .processing:        return "Transcribing (Whisper CPU, ~15–30 s)…"
        case .routing:           return "Understanding…"
        case .error(let msg):    return "Voice: \(msg)"
        case .stopped:           return "Voice off"
        }
    }
}

// MARK: - Model download section

private struct ModelDownloadSection: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject var service: ModelDownloadService
    let visibleIds: [ModelID]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice models")
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(visibleIds, id: \.rawValue) { id in
                if let entry = ModelCatalog.entry(for: id) {
                    ModelRow(entry: entry,
                             state: service.states[id] ?? (coordinator.modelStore.isCached(id) ? .completed : .notStarted),
                             runtimeStatus: runtimeStatus(for: entry),
                             onStart: { service.start(id) },
                             onCancel: { service.cancel(id) },
                             onDelete: {
                                 try? coordinator.modelStore.delete(id)
                                 service.reset(id)
                             })
                }
            }

            let needsLinking = visibleIds.contains { id in
                guard let entry = ModelCatalog.entry(for: id),
                      coordinator.modelStore.isCached(id) else { return false }
                if case .notLinked = runtimeStatus(for: entry) { return true }
                return false
            }
            if needsLinking {
                Divider()
                Text("Model downloaded, but its runtime engine isn't linked into this build. Rebuild after adding the SPM package (see docs/voice-pipeline-setup.md).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundColor(.secondary)
                Text("STT in use: \(coordinator.activeSTTName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(12)
    }

    /// Whether the *runtime* for this kind is linked into the app. Model on
    /// disk without a runtime is a Phase-1 halfway state — the download UI
    /// should say so instead of showing a green check that pretends the
    /// feature is live.
    private func runtimeStatus(for entry: ModelCatalogEntry) -> RuntimeStatus {
        switch entry.kind {
        case .whisperBase, .whisperLoRA:
            #if canImport(SwiftWhisper)
            return .linked
            #else
            return .notLinked(engine: "whisper.cpp")
            #endif
        case .llamaBase, .llamaLoRA:
            #if canImport(LLM)
            return .linked
            #else
            return .notLinked(engine: "llama.cpp")
            #endif
        case .vad:
            #if canImport(onnxruntime_objc)
            return .linked
            #else
                return .notLinked(engine: "onnxruntime")
            #endif
        case .tts:
            return .notLinked(engine: "sherpa-onnx")
        }
    }
}

private enum RuntimeStatus: Equatable {
    case linked
    case notLinked(engine: String)
}

private struct ModelRow: View {
    let entry: ModelCatalogEntry
    let state: ModelDownloadState
    let runtimeStatus: RuntimeStatus
    let onStart: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.displayName)
                    .font(.body)
                Spacer()
                actionButton
                if case .completed = state {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            statusLine
            runtimeLine
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var runtimeLine: some View {
        if case .completed = state {
            switch runtimeStatus {
            case .linked:
                Label("Active", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case .notLinked(let engine):
                Label("Downloaded, runtime not yet linked (\(engine))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .notStarted, .failed, .cancelled:
            Button("Download", action: onStart)
                .buttonStyle(.borderedProminent)
        case .queued, .downloading, .verifying:
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
        case .completed:
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .notStarted:
            Text("\(sizeString) — not downloaded yet")
                .font(.caption)
                .foregroundColor(.secondary)
        case .queued:
            Text("Queued…")
                .font(.caption)
                .foregroundColor(.secondary)
        case .downloading(let received, let total):
            let ratio = total > 0 ? Double(received) / Double(total) : 0
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: ratio)
                Text("\(bytes(received)) of \(bytes(total))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .verifying:
            Text("Verifying integrity…")
                .font(.caption)
                .foregroundColor(.secondary)
        case .completed:
            Text("Ready")
                .font(.caption)
                .foregroundColor(.green)
        case .failed(let reason):
            Text("Failed: \(reason)")
                .font(.caption)
                .foregroundColor(.red)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var sizeString: String { bytes(entry.sizeBytes) }

    private func bytes(_ n: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: n)
    }
}
