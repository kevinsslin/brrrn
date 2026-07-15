import SwiftUI
import BrrrnCore

/// In-app crew setup: start a pit or join one with a code, no terminal
/// needed. The heavy lifting (handle claim, secret, config write, backfill)
/// stays in the CLI, which this drives.
struct PitSetupSheet: View {
    @ObservedObject var model: AppModel
    /// Screenshot generator: AppKit-backed text fields cannot offscreen-
    /// render, so this swaps them for static lookalikes.
    var snapshotMode = false
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable {
        case create = "Start a pit"
        case join = "Join with code"
    }

    @State private var mode: Mode = .join
    @State private var handle = ""
    @State private var pitName = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var createdCode: String?
    @State private var copied = false

    private var lockedHandle: String? {
        let existing = model.config?.handle ?? ""
        return existing.isEmpty ? nil : existing
    }

    private var effectiveHandle: String {
        (lockedHandle ?? handle).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var canSubmit: Bool {
        guard !isWorking, !effectiveHandle.isEmpty else { return false }
        return mode == .create || !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let createdCode {
                success(code: createdCode)
            } else {
                form
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    private var form: some View {
        Group {
            Text("FRIENDS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)

            TabStrip(
                selection: $mode,
                options: Mode.allCases.map { ($0, $0.rawValue) }
            )

            if mode == .create {
                field("Pit name (optional)", text: $pitName, sample: "night shift")
            } else {
                field("Join code, like ember-fox-7k2m", text: $code, sample: "ember-fox-7k2m", monospaced: true)
            }

            if let lockedHandle {
                LabeledContent("Handle", value: lockedHandle)
                    .font(.callout)
                    .help("This machine already burns as \(lockedHandle); one handle per client.")
            } else {
                field("Your handle", text: $handle, sample: "mitsuha")
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .create ? "Create & join" : "Join")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }

            Text("Joining uploads daily totals only: costs and token counts per UTC day, never prompts or code.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func field(
        _ placeholder: String,
        text: Binding<String>,
        sample: String,
        monospaced: Bool = false
    ) -> some View {
        if snapshotMode {
            Text(sample)
                .font(monospaced ? .body.monospaced() : .body)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        } else if monospaced {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        } else {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func success(code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pit created", systemImage: "flame.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("You're in. Send this code to your crew:")
                .font(.callout)
            HStack {
                Text(code)
                    .font(.title3.weight(.semibold).monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func submit() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            switch mode {
            case .create:
                let trimmedName = pitName.trimmingCharacters(in: .whitespaces)
                createdCode = try await model.createPit(
                    name: trimmedName.isEmpty ? nil : trimmedName,
                    handle: effectiveHandle
                )
            case .join:
                try await model.joinPit(
                    code: code.trimmingCharacters(in: .whitespaces).lowercased(),
                    handle: effectiveHandle
                )
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
