import SwiftUI

/// Lets the user browse Google Drive folders and select one as their audiobook library.
/// Uses NavigationLink drill-down — each folder tap pushes a new level onto the stack.
struct FolderPickerView: View {
    let driveService: GoogleDriveService
    let folderId: String
    let folderName: String

    @EnvironmentObject var appVM: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var folders: [DriveItem] = []
    @State private var isLoading = false
    @State private var error: String?

    /// Convenience init for the root level (Google Drive root)
    init(driveService: GoogleDriveService) {
        self.driveService = driveService
        self.folderId = "root"
        self.folderName = "Google Drive"
    }

    /// Init for a specific subfolder (used by NavigationLink drill-down)
    init(driveService: GoogleDriveService, folderId: String, folderName: String) {
        self.driveService = driveService
        self.folderId = folderId
        self.folderName = folderName
    }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if folders.isEmpty && error == nil {
                ContentUnavailableView(
                    "No Folders",
                    systemImage: "folder",
                    description: Text("This folder doesn't contain any subfolders.")
                )
                .listRowBackground(Color.clear)
            }

            ForEach(folders) { folder in
                NavigationLink {
                    FolderPickerView(
                        driveService: driveService,
                        folderId: folder.id,
                        folderName: folder.name
                    )
                } label: {
                    Label(folder.name, systemImage: "folder.fill")
                }
            }
        }
        .navigationTitle(folderName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Select This Folder") {
                    appVM.addLibrary(folderId: folderId, folderName: folderName)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .alert("Error", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task {
            await loadFolders()
        }
    }

    private func loadFolders() async {
        isLoading = true
        error = nil
        do {
            guard let credential = await driveService.oauthCredential() else {
                throw DriveError.notAuthenticated
            }
            folders = try await driveService.listFolders(in: folderId, credential: credential)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
