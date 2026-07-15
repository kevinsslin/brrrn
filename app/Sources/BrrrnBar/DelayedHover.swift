import SwiftUI

/// Hover intent with a short grace period: the binding turns true only after
/// the cursor has rested on the view, so popovers do not fire while the user
/// is scrolling past. Leaving cancels a pending activation and clears
/// immediately.
private struct DelayedHover: ViewModifier {
    @Binding var isActive: Bool
    var delay: Duration

    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                pending = nil
                if hovering {
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: delay)
                        guard !Task.isCancelled else { return }
                        isActive = true
                    }
                } else {
                    isActive = false
                }
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
            }
    }
}

extension View {
    func delayedHover(_ isActive: Binding<Bool>, delay: Duration = .milliseconds(350)) -> some View {
        modifier(DelayedHover(isActive: isActive, delay: delay))
    }
}
