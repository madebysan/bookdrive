import SwiftUI
import UniformTypeIdentifiers

/// Settings screen — presented as a sheet from the library toolbar.
/// Covers account, library management, downloads, and storage.
struct SettingsView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showDownloadAllConfirmation = false
    @State private var showDownloadFilteredConfirmation = false
    @State private var showClearDownloadsConfirmation = false
    @State private var showClearCacheConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var downloadedSize: String = ""
    @State private var metadataCacheSize: String = ""
    @State private var isRefreshingMetadata = false
    @State private var isLookingUpCovers = false
    @State private var showClearAPICoversConfirmation = false
    @State private var showRefreshMetadataConfirmation = false
    @State private var showImportPicker = false
    @State private var showImportResult = false
    @State private var importResultMessage = ""
    @AppStorage("appearance") private var appearance: Int = 0

    var body: some View {
        settingsList
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { updateSizes() }
            .modifier(SettingsAlerts(
                showRenameAlert: $showRenameAlert,
                showDownloadAllConfirmation: $showDownloadAllConfirmation,
                showDownloadFilteredConfirmation: $showDownloadFilteredConfirmation,
                showClearDownloadsConfirmation: $showClearDownloadsConfirmation,
                showClearCacheConfirmation: $showClearCacheConfirmation,
                showClearAPICoversConfirmation: $showClearAPICoversConfirmation,
                showRefreshMetadataConfirmation: $showRefreshMetadataConfirmation,
                showSignOutConfirmation: $showSignOutConfirmation,
                renameText: $renameText,
                onRename: { appVM.renameLibrary(renameText) },
                onDownloadAll: { libraryVM.downloadAll() },
                onDownloadFiltered: { libraryVM.downloadFiltered() },
                onClearDownloads: { clearAllDownloads() },
                onClearCache: { clearMetadataCache() },
                onClearAPICovers: { libraryVM.clearAllAPICovers() },
                onRefreshMetadata: {
                    isRefreshingMetadata = true
                    Task {
                        await libraryVM.refreshAllMetadata()
                        isRefreshingMetadata = false
                    }
                },
                onSignOut: { auth.signOut(); appVM.handleSignOut() },
                downloadAllCount: libraryVM.nonDownloadedCount,
                downloadFilteredCount: libraryVM.nonDownloadedFilteredCount
            ))
    }

    // MARK: - List Content

    private var settingsList: some View {
        List {
            accountSection
            appearanceSection
            librarySection
            backupSection
            downloadsSection
            storageSection
            aboutSection
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                Text("System").tag(0)
                Text("Light").tag(1)
                Text("Dark").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Image(systemName: "person.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.userName ?? "Signed in")
                        .font(.body)
                    if let email = auth.userEmail {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Sign Out", role: .destructive) {
                showSignOutConfirmation = true
            }
        }
    }

    private var librarySection: some View {
        Section("Library") {
            HStack {
                Text("Name")
                Spacer()
                Text(appVM.displayLibraryName)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                renameText = appVM.activeLibrary?.name ?? ""
                showRenameAlert = true
            }

            Button {
                showRefreshMetadataConfirmation = true
            } label: {
                HStack {
                    Text("Refresh Covers & Metadata")
                    Spacer()
                    if isRefreshingMetadata {
                        ProgressView()
                    }
                }
            }
            .disabled(isRefreshingMetadata)

            Button {
                isLookingUpCovers = true
                Task {
                    await libraryVM.lookUpMissingCovers()
                    isLookingUpCovers = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Look Up Missing Covers")
                        Spacer()
                        if isLookingUpCovers || libraryVM.isLookingUpCovers {
                            if libraryVM.coverLookupTotal > 0 {
                                Text("\(libraryVM.coverLookupProgress)/\(libraryVM.coverLookupTotal)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView()
                        }
                    }
                    Text("Searches iTunes, Google Books, and Open Library for cover art using book titles. Does not download audio files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isLookingUpCovers || libraryVM.isLookingUpCovers)

            Button(role: .destructive) {
                showClearAPICoversConfirmation = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clear API Covers")
                    Text("Removes covers fetched from iTunes, Google Books, and Open Library. Keeps embedded covers from audio files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var backupSection: some View {
        Section {
            Button {
                exportProgress()
            } label: {
                Label("Export Progress", systemImage: "square.and.arrow.up")
            }

            Button {
                showImportPicker = true
            } label: {
                Label("Import Progress", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Export saves your listening positions and bookmarks as a JSON file. Import restores them by matching file paths.")
        }
        .sheet(isPresented: $showImportPicker) {
            DocumentPicker(types: [.json]) { url in
                importProgress(from: url)
            }
        }
        .alert("Import Complete", isPresented: $showImportResult) {
            Button("OK") {}
        } message: {
            Text(importResultMessage)
        }
    }

    private var downloadsSection: some View {
        Section("Downloads") {
            Button {
                showDownloadAllConfirmation = true
            } label: {
                HStack {
                    Text("Download All")
                    Spacer()
                    Text("\(libraryVM.nonDownloadedCount) books")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(libraryVM.nonDownloadedCount == 0)

            if libraryVM.filter != .all || libraryVM.selectedGenre != nil {
                Button {
                    showDownloadFilteredConfirmation = true
                } label: {
                    HStack {
                        Text("Download Visible")
                        Spacer()
                        Text("\(libraryVM.nonDownloadedFilteredCount) books")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(libraryVM.nonDownloadedFilteredCount == 0)
            }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            HStack {
                Text("Downloads")
                Spacer()
                Text(downloadedSize)
                    .foregroundStyle(.secondary)
            }

            Button("Clear All Downloads", role: .destructive) {
                showClearDownloadsConfirmation = true
            }

            HStack {
                Text("Metadata Cache")
                Spacer()
                Text(metadataCacheSize)
                    .foregroundStyle(.secondary)
            }

            Button("Clear Metadata Cache", role: .destructive) {
                showClearCacheConfirmation = true
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            Link(destination: AppLinks.support) {
                Label("Support", systemImage: "questionmark.circle")
            }

            Link(destination: AppLinks.privacy) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - Helpers

    private func updateSizes() {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        Task.detached(priority: .utility) {
            let bytes = DownloadManager.totalDownloadedSize()
            await MainActor.run { downloadedSize = formatter.string(fromByteCount: bytes) }
        }
        let cacheBytes = libraryVM.books.reduce(Int64(0)) { $0 + Int64($1.coverArtData?.count ?? 0) }
        metadataCacheSize = formatter.string(fromByteCount: cacheBytes)
    }

    private func clearAllDownloads() {
        for book in libraryVM.books { libraryVM.deleteDownload(for: book) }
        updateSizes()
    }

    private func clearMetadataCache() {
        _ = libraryVM.clearMetadataCache()
        updateSizes()
    }

    private func exportProgress() {
        guard let data = libraryVM.exportProgressData() else { return }
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("audiobook-progress.json")
        do {
            try data.write(to: fileURL)
        } catch {
            print("Export failed: \(error)")
            return
        }

        // Present UIActivityViewController from the root view controller
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        // Walk to the topmost presented controller (the settings sheet)
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        // iPad popover anchor
        activityVC.popoverPresentationController?.sourceView = presenter.view
        activityVC.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        presenter.present(activityVC, animated: true)
    }

    private func importProgress(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            if let summary = libraryVM.importProgress(from: data) {
                importResultMessage = summary
            } else {
                importResultMessage = "Could not read the progress file. It may be in an unsupported format."
            }
        } catch {
            importResultMessage = "Failed to read file: \(error.localizedDescription)"
        }
        showImportResult = true
    }
}

// MARK: - Alert ViewModifier (extracted to help the Swift type-checker)

/// Groups all Settings alerts into one ViewModifier so the body stays under the type-checker limit.
private struct SettingsAlerts: ViewModifier {
    @Binding var showRenameAlert: Bool
    @Binding var showDownloadAllConfirmation: Bool
    @Binding var showDownloadFilteredConfirmation: Bool
    @Binding var showClearDownloadsConfirmation: Bool
    @Binding var showClearCacheConfirmation: Bool
    @Binding var showClearAPICoversConfirmation: Bool
    @Binding var showRefreshMetadataConfirmation: Bool
    @Binding var showSignOutConfirmation: Bool
    @Binding var renameText: String

    var onRename: () -> Void
    var onDownloadAll: () -> Void
    var onDownloadFiltered: () -> Void
    var onClearDownloads: () -> Void
    var onClearCache: () -> Void
    var onClearAPICovers: () -> Void
    var onRefreshMetadata: () -> Void
    var onSignOut: () -> Void
    var downloadAllCount: Int
    var downloadFilteredCount: Int

    func body(content: Content) -> some View {
        content
            .alert("Rename Library", isPresented: $showRenameAlert) {
                TextField("Library name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") { onRename() }
            } message: {
                Text("Leave empty to use the Drive folder name.")
            }
            .alert("Download All", isPresented: $showDownloadAllConfirmation) {
                Button("Download \(downloadAllCount) Books") { onDownloadAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Download \(downloadAllCount) books for offline listening?")
            }
            .alert("Download Visible", isPresented: $showDownloadFilteredConfirmation) {
                Button("Download \(downloadFilteredCount) Books") { onDownloadFiltered() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Download visible books for offline listening?")
            }
            .alert("Clear All Downloads?", isPresented: $showClearDownloadsConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { onClearDownloads() }
            } message: {
                Text("Downloaded audiobook files will be deleted. Listening progress is kept.")
            }
            .alert("Clear Metadata Cache?", isPresented: $showClearCacheConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { onClearCache() }
            } message: {
                Text("Cover art and book details will be re-fetched on the next sync.")
            }
            .alert("Clear API Covers?", isPresented: $showClearAPICoversConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { onClearAPICovers() }
            } message: {
                Text("Covers fetched from online APIs will be removed. Embedded covers from audio files are kept. Use \"Look Up Missing Covers\" to re-fetch.")
            }
            .alert("Refresh Metadata?", isPresented: $showRefreshMetadataConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Refresh") { onRefreshMetadata() }
            } message: {
                Text("This will re-fetch cover art and metadata for all books. It may take a while.")
            }
            .alert("Sign Out?", isPresented: $showSignOutConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) { onSignOut() }
            } message: {
                Text("You'll need to sign in again to access your audiobooks.")
            }
    }
}

// MARK: - UIKit Wrappers

/// Wraps UIDocumentPickerViewController for importing files
private struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
