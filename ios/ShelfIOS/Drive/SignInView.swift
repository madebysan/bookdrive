import SwiftUI

/// Welcome screen shown when the user is not signed in. Explains what Bookdrive does
/// before asking for Google sign-in. Picked from three prototypes on 2026-10-18.
struct SignInView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @State private var appeared = false

    private struct Feature {
        let symbol: String
        let title: String
        let detail: String
    }

    private let features = [
        Feature(symbol: "folder.fill", title: "Your Drive is your library",
                detail: "Choose a Google Drive folder of audiobooks, lectures or videos. Bookdrive turns it into a shelf you can browse and play."),
        Feature(symbol: "arrow.down.circle.fill", title: "Download once, listen anywhere",
                detail: "Downloaded books are saved on this iPhone and play without a connection. Bookdrive remembers your place in each one."),
        Feature(symbol: "lock.fill", title: "Private by design",
                detail: "There's no Bookdrive account or server. The app gets read-only access, so it can't change or delete anything in your Drive."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AppIconImage(size: 84)
                    .padding(.top, 48)
                    .appearing(appeared)

                Text("Welcome to Bookdrive")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
                    .appearing(appeared, delay: 0.05)

                VStack(alignment: .leading, spacing: 28) {
                    ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: feature.symbol)
                                .font(.title)
                                .foregroundStyle(AppColors.brandTeal)
                                .frame(width: 40)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.title)
                                    .font(.headline)
                                Text(feature.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .appearing(appeared, delay: 0.15 + Double(index) * 0.07)
                    }
                }
                .padding(.top, 40)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 14) {
                SignInWithGoogleButton { auth.signIn() }

                if let error = auth.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(AppColors.destructive)
                        .multilineTextAlignment(.center)
                }

                Link("Privacy Policy", destination: AppLinks.privacy)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Color(.systemBackground))
        }
        .onAppear { appeared = true }
    }
}

/// The app icon as an in-app image, masked like the Home Screen.
struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image("BrandIcon")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// "Sign in with Google" built to Google's branding guidelines
/// (https://developers.google.com/identity/branding-guidelines): the standard-color G,
/// light theme (#FFFFFF fill, #747775 inside stroke, #1F1F1F text) in light mode and
/// dark theme (#131314 fill, #8E918F stroke, #E3E3E3 text) in dark mode.
/// Google specifies Google Sans; the system font stands in because it isn't bundled.
struct SignInWithGoogleButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var logoSize: CGFloat = 20

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("GoogleG")
                    .resizable()
                    .frame(width: logoSize, height: logoSize)
                    .accessibilityHidden(true)
                Text("Sign in with Google")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(GoogleButtonStyle(isDark: colorScheme == .dark))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private struct GoogleButtonStyle: ButtonStyle {
        let isDark: Bool

        private static let lightText = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)
        private static let lightStroke = Color(red: 0x74 / 255, green: 0x77 / 255, blue: 0x75 / 255)
        private static let darkFill = Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x14 / 255)
        private static let darkStroke = Color(red: 0x8E / 255, green: 0x91 / 255, blue: 0x8F / 255)
        private static let darkText = Color(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE3 / 255)

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(isDark ? Self.darkText : Self.lightText)
                .background(isDark ? Self.darkFill : Color.white, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(isDark ? Self.darkStroke : Self.lightStroke, lineWidth: 1)
                }
                .overlay {
                    // Material pressed-state layer
                    Capsule().fill((isDark ? Color.white : Self.lightText).opacity(configuration.isPressed ? 0.12 : 0))
                }
                .contentShape(Capsule())
                .animation(AppAnimation.quickToggle, value: configuration.isPressed)
        }
    }
}

/// Fades content up into place once. Reduce Motion keeps the fade and drops the travel.
private struct Appearing: ViewModifier {
    let appeared: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            .animation(AppAnimation.stateAppear.delay(delay), value: appeared)
    }
}

private extension View {
    func appearing(_ appeared: Bool, delay: Double = 0) -> some View {
        modifier(Appearing(appeared: appeared, delay: delay))
    }
}
