import Foundation
import GoogleSignIn

/// Wraps Google Sign-In SDK — handles authentication and token management.
/// The access token includes the Drive read-only scope for listing and downloading files.
@MainActor
class GoogleAuthService: ObservableObject {

    @Published var isSignedIn: Bool = false
    @Published var userName: String?
    @Published var userEmail: String?
    @Published var error: String?

    /// The current valid access token (refreshed automatically by the SDK)
    var accessToken: String? {
        GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString
    }

    // Drive read-only scope — lets us list folders and download files
    private let driveScope = "https://www.googleapis.com/auth/drive.readonly"

    init() {
        // Check if the user is already signed in from a previous session
        restorePreviousSignIn()
    }

    /// Attempts to restore a previous sign-in session (persisted by the SDK)
    func restorePreviousSignIn() {
        GIDSignIn.sharedInstance.restorePreviousSignIn { [weak self] user, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let user = user {
                    self.updateUser(user)
                    // Ensure we still have the Drive scope
                    // Note: grantedScopes can be nil during session restore even when
                    // the user is properly authenticated — only sign out if scopes are
                    // explicitly present but missing the Drive scope.
                    if let scopes = user.grantedScopes,
                       !scopes.contains(self.driveScope) {
                        self.isSignedIn = false
                    }
                } else {
                    self.isSignedIn = false
                }
            }
        }
    }

    /// Initiates the Google Sign-In flow
    func signIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            error = "Cannot find root view controller"
            return
        }

        // Request Drive read-only scope during sign-in
        let config = GIDConfiguration(clientID: Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "")
        GIDSignIn.sharedInstance.configuration = config

        GIDSignIn.sharedInstance.signIn(withPresenting: rootVC, hint: nil, additionalScopes: [driveScope]) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    self.error = error.localizedDescription
                    return
                }
                if let user = result?.user {
                    self.updateUser(user)
                }
            }
        }
    }

    /// Signs out and clears state
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        isSignedIn = false
        userName = nil
        userEmail = nil
    }

    /// Refreshes the access token if it's expired
    func refreshTokenIfNeeded() async -> String? {
        guard let user = GIDSignIn.sharedInstance.currentUser else { return nil }

        // If the token is still valid, return it
        if let expiration = user.accessToken.expirationDate, expiration > Date() {
            return user.accessToken.tokenString
        }

        // Otherwise refresh
        return await withCheckedContinuation { continuation in
            user.refreshTokensIfNeeded { user, error in
                continuation.resume(returning: user?.accessToken.tokenString)
            }
        }
    }

    /// Handles the OAuth redirect URL from Google
    func handleURL(_ url: URL) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: - Private

    private func updateUser(_ user: GIDGoogleUser) {
        isSignedIn = true
        userName = user.profile?.name
        userEmail = user.profile?.email
        error = nil
    }
}
