import SwiftUI

// MARK: - Staggered List Appearance

/// Makes list rows enter one at a time with a slight upward slide.
/// Apply to each row: `.staggeredAppear(index: idx)`
struct StaggeredAppear: ViewModifier {
    let index: Int
    /// When false the row appears immediately. List rows are recreated every time
    /// they scroll back on screen, so the animation must only run on the first load.
    let enabled: Bool
    private let maxStagger = 15 // Cap so long lists don't delay forever
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || !enabled ? 1 : 0)
            .offset(y: appeared || !enabled ? 0 : 6)
            .onAppear {
                guard enabled, !appeared else { return }
                let delay = Double(min(index, maxStagger)) * 0.015
                withAnimation(AppAnimation.appear.delay(delay)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Empty State Appearance

/// Fade + scale entrance for empty/loading states.
/// Apply: `.emptyStateAppear()`
struct EmptyStateAppear: ViewModifier {
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(visible ? 1.0 : 0.94)
            .opacity(visible ? 1.0 : 0.0)
            .onAppear {
                withAnimation(AppAnimation.stateAppear.delay(0.05)) {
                    visible = true
                }
            }
    }
}

// MARK: - Haptic Feedback

/// Fires a haptic tap. Call from any action handler.
enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - View Extensions

extension View {
    func staggeredAppear(index: Int, enabled: Bool = true) -> some View {
        modifier(StaggeredAppear(index: index, enabled: enabled))
    }

    func emptyStateAppear() -> some View {
        modifier(EmptyStateAppear())
    }
}
