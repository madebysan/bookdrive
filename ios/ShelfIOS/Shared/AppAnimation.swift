import SwiftUI

/// Centralized animation curves for the entire app.
/// Every `withAnimation` call should use one of these named values.
enum AppAnimation {
    /// Filter chip selection, layout toggle — quick, no bounce
    static let quickToggle = Animation.easeInOut(duration: 0.2)

    /// List/grid layout switch — content crossfade
    static let viewSwitch = Animation.easeInOut(duration: 0.25)

    /// New item or row appearing in a list — gentle settle
    static let appear = Animation.spring(duration: 0.18, bounce: 0.12)

    /// Status badge changes (download complete, now-playing indicator) — smooth handoff
    static let statusChange = Animation.easeInOut(duration: 0.3)

    /// NowPlayingBar sliding in/out — physical, has weight
    static let barReveal = Animation.spring(duration: 0.4, bounce: 0.15)

    /// Empty/loading state fading in — atmospheric, no bounce
    static let stateAppear = Animation.easeOut(duration: 0.4)
}
