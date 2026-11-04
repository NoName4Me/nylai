import SwiftUI

private struct NylaiLocalizationModifier: ViewModifier {
    @State private var revision = 0

    func body(content: Content) -> some View {
        content
            .environment(\.locale, L10n.shared.locale)
            .id(revision)
            .transition(.opacity)
            .onReceive(
                NotificationCenter.default.publisher(for: .nylaiLanguageDidChange)
            ) { _ in
                withAnimation(.easeInOut(duration: 0.16)) {
                    revision &+= 1
                }
            }
    }
}

extension View {
    func nylaiLocalized() -> some View {
        modifier(NylaiLocalizationModifier())
    }
}
