import SwiftUI
import BrrrnCore

/// In-app crew setup: start a pit or join one with a code, no terminal
/// needed. The heavy lifting (handle claim, secret, config write, backfill)
/// stays in the CLI, which this drives. Rendered inline in the menu window
/// (a sheet would steal key status and close the MenuBarExtra popover).
struct PitSetupView: View {
    @ObservedObject var model: AppModel
    /// Screenshot generator: AppKit-backed text fields cannot offscreen-
    /// render, so this swaps them for static lookalikes.
    var snapshotMode = false
    let onClose: () -> Void

    private enum Mode: String, CaseIterable {
        case create = "Start a pit"
        case join = "Join with code"
    }

    @State private var mode: Mode = .join
    @State private var displayName = ""
    @State private var pitName = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var createdCode: String?
    @State private var copied = false

    private var existingHandle: String? {
        let existing = model.config?.handle ?? ""
        return existing.isEmpty ? nil : existing
    }

    private var canSubmit: Bool {
        guard !isWorking else { return false }
        // First-time joiners need a display name: their ID is auto-generated
        // machine noise, and a board of u3f9a2c rows helps nobody.
        if existingHandle == nil
            && displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return mode == .create || !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("FRIENDS").font(.headline)
                Spacer()
                Color.clear.frame(width: 45, height: 1)
            }
            .padding(14)
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if let createdCode {
                    success(code: createdCode)
                } else {
                    form
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Fill the whole menu window; without this the stack renders at its
        // natural height and floats vertically centered.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var form: some View {
        Group {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Burn with your crew")
                        .font(.headline)
                    Text("One of you starts a pit; everyone joins with its code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

            TabStrip(
                selection: $mode,
                options: Mode.allCases.map { ($0, $0.rawValue) }
            )
            .padding(.bottom, 4)

            if mode == .create {
                labeledField(
                    label: "PIT NAME (OPTIONAL)",
                    placeholder: "night shift",
                    text: $pitName,
                    sample: "night shift"
                )
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    labeledField(
                        label: "INVITE FROM YOUR FRIEND",
                        placeholder: "paste it here",
                        text: $code,
                        sample: "ember-fox-7k2m",
                        monospaced: true
                    )
                    Text("Paste exactly what they sent: the whole invite (code@hub) or just the code if you already use the same hub.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            labeledField(
                label: existingHandle == nil ? "YOUR NAME" : "YOUR NAME (OPTIONAL)",
                placeholder: "Mitsuha",
                text: $displayName,
                sample: "Mitsuha"
            )
            if let existingHandle {
                Text("Joining as @\(existingHandle); leave the name empty to keep your current one.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await submit() }
            } label: {
                Group {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .create ? "Create & join" : "Join the pit")
                            .font(.callout.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
            .padding(.top, 4)

            Label(
                "Uploads daily totals only: costs and token counts per UTC day. Never prompts or code.",
                systemImage: "lock.fill"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(1.1)
    }

    private func labeledField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        sample: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            field(placeholder, text: text, sample: sample, monospaced: monospaced)
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
            Button("Done") { onClose() }
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
                let display = displayName.trimmingCharacters(in: .whitespaces)
                createdCode = try await model.createPit(
                    name: trimmedName.isEmpty ? nil : trimmedName,
                    displayName: display.isEmpty ? nil : display
                )
            case .join:
                let display = displayName.trimmingCharacters(in: .whitespaces)
                let invite = PitInvite.parse(code)
                try await model.joinPit(
                    code: invite.code,
                    displayName: display.isEmpty ? nil : display,
                    inviteHubURL: invite.hubURL
                )
                onClose()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
