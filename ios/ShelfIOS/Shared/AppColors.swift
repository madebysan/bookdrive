import SwiftUI

/// Centralized color palette for the app.
/// All views should reference these instead of hardcoding colors inline.
enum AppColors {
    // MARK: - Accent & Brand
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.15)
    /// The teal of the app icon's bookshelf, lifted in dark mode for contrast.
    static let brandTeal = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x5F / 255, green: 0xB8 / 255, blue: 0xB2 / 255, alpha: 1)
            : UIColor(red: 0x1B / 255, green: 0x68 / 255, blue: 0x65 / 255, alpha: 1)
    })

    // MARK: - Surface & Background
    static let secondaryFill = Color(.secondarySystemFill)

    // MARK: - Status
    static let downloaded = Color.green
    static let destructive = Color.red

    // MARK: - Progress
    static let progressTrack = Color.secondary.opacity(0.2)
    static let progressFill = Color.accentColor

    // MARK: - Scrubber / Drag Handle
    static let dragHandle = Color.secondary.opacity(0.5)
}
