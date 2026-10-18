import SwiftUI

/// Main library screen — shows all audiobooks with search, sort, and filter chips.
/// Supports list and grid layouts via a toggle in the toolbar menu.
struct LibraryView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playerVM: PlayerViewModel
    @EnvironmentObject var appVM: AppViewModel
    @State private var showGenreSheet = false
    @State private var showManageSheet = false
    @State private var showSortSheet = false
    @State private var showSettingsSheet = false
    @AppStorage("libraryLayoutIsGrid") private var isGridLayout: Bool = false
    /// Rows animate in only on the first load; afterwards they appear instantly so
    /// scrolling back to a row does not replay the entrance.
    @State private var introAnimationsEnabled = true

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    /// Groups displayBooks by subfolder for section display
    private var subfolderSections: [SubfolderSection] {
        var grouped: [String: [Book]] = [:]
        for book in libraryVM.displayBooks {
            let key = book.displaySubfolder ?? "Root"
            grouped[key, default: []].append(book)
        }
        return grouped.keys.sorted { a, b in
            if a == "Root" { return false }
            if b == "Root" { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }.map { SubfolderSection(name: $0, books: grouped[$0]!) }
    }

    var body: some View {
        Group {
            if isGridLayout {
                gridContent
            } else {
                listContent
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $libraryVM.searchText, prompt: "Search library")
        .refreshable {
            if let library = appVM.activeLibrary {
                await libraryVM.syncLibrary(library)
            }
        }
        .toolbar {
            libraryToolbarLeading
            libraryToolbarTrailing
        }
        .sheet(isPresented: $showGenreSheet) {
            GenreBrowseSheet()
        }
        .sheet(isPresented: $showSortSheet) {
            SortSheet()
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                SettingsView()
            }
        }
        .sheet(isPresented: $showManageSheet) {
            ManageLibrariesSheet()
        }
        .safeAreaInset(edge: .top) {
            genreChip
        }
        .onChange(of: libraryVM.displayBooks.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty, introAnimationsEnabled else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                introAnimationsEnabled = false
            }
        }
    }

    // MARK: - Filter Chips (shared)

    private var filterChipsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(libraryVM.visibleFilters, id: \.self) { filter in
                    FilterChip(
                        title: filter.rawValue,
                        isSelected: libraryVM.filter == filter
                    ) {
                        Haptics.selection()
                        withAnimation(AppAnimation.quickToggle) {
                            libraryVM.filter = filter
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Loading & Empty States (shared)

    private var loadingState: some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading library...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var emptyState: some View {
        if libraryVM.filter != .all && libraryVM.searchText.isEmpty {
            ContentUnavailableView(
                "No Books",
                systemImage: "book.closed",
                description: Text("No books match the \"\(libraryVM.filter.rawValue)\" filter.")
            )
        } else {
            ContentUnavailableView.search(text: libraryVM.searchText)
        }
    }

    // MARK: - List Layout

    private var listContent: some View {
        List {
            Section {
                filterChipsSection
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if libraryVM.isLoading && libraryVM.books.isEmpty {
                loadingState
                    .listRowBackground(Color.clear)
                    .emptyStateAppear()
            } else if libraryVM.displayBooks.isEmpty {
                emptyState
                    .emptyStateAppear()
            } else if libraryVM.sortOrder == .subfolder {
                ForEach(subfolderSections, id: \.name) { section in
                    Section(header: Text(section.name)) {
                        ForEach(Array(section.books.enumerated()), id: \.element.objectID) { index, book in
                            BookRowView(book: book)
                                .staggeredAppear(index: index, enabled: introAnimationsEnabled)
                        }
                    }
                }
            } else {
                ForEach(Array(libraryVM.displayBooks.enumerated()), id: \.element.objectID) { index, book in
                    BookRowView(book: book)
                        .staggeredAppear(index: index, enabled: introAnimationsEnabled)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Grid Layout

    private var gridContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Filter chips at the top
                filterChipsSection
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if libraryVM.isLoading && libraryVM.books.isEmpty {
                    loadingState
                        .emptyStateAppear()
                } else if libraryVM.displayBooks.isEmpty {
                    emptyState
                        .padding(.top, 40)
                        .emptyStateAppear()
                } else if libraryVM.sortOrder == .subfolder {
                    // Grouped by subfolder — each section gets its own grid
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: .sectionHeaders) {
                        ForEach(subfolderSections, id: \.name) { section in
                            Section {
                                LazyVGrid(columns: gridColumns, spacing: 16) {
                                    ForEach(Array(section.books.enumerated()), id: \.element.objectID) { index, book in
                                        BookGridCardView(book: book)
                                            .staggeredAppear(index: index, enabled: introAnimationsEnabled)
                                    }
                                }
                            } header: {
                                Text(section.name)
                                    .font(.headline)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.bar)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(Array(libraryVM.displayBooks.enumerated()), id: \.element.objectID) { index, book in
                            BookGridCardView(book: book)
                                .staggeredAppear(index: index, enabled: introAnimationsEnabled)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Genre Chip

    @ViewBuilder
    private var genreChip: some View {
        if let genre = libraryVM.selectedGenre {
            HStack {
                Text(genre)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Button {
                    libraryVM.selectedGenre = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(AppColors.accentSoft)
            .clipShape(Capsule())
            .padding(.bottom, 4)
        }
    }

    // MARK: - Toolbar

    private var libraryToolbarLeading: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(appVM.allLibraries, id: \.objectID) { library in
                    Button {
                        // MainTabView reloads and syncs when the active library changes
                        appVM.switchToLibrary(library)
                    } label: {
                        HStack {
                            Text("\(library.displayName) (\(library.bookCount))")
                            if library.id == appVM.activeLibraryId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    showManageSheet = true
                } label: {
                    Label("Manage Libraries", systemImage: "folder.badge.gearshape")
                }
            } label: {
                HStack(spacing: 6) {
                    Text(appVM.displayLibraryName)
                        .font(.headline)
                    if libraryVM.isFetchingMetadata || libraryVM.isLookingUpCovers {
                        ProgressView()
                            .controlSize(.small)
                        if libraryVM.isFetchingMetadata, libraryVM.metadataTotal > 0 {
                            Text("\(libraryVM.metadataProgress)/\(libraryVM.metadataTotal)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private var libraryToolbarTrailing: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // Layout toggle
                Button {
                    Haptics.light()
                    withAnimation(AppAnimation.viewSwitch) {
                        isGridLayout.toggle()
                    }
                } label: {
                    Label(
                        isGridLayout ? "List View" : "Grid View",
                        systemImage: isGridLayout ? "list.bullet" : "square.grid.2x2"
                    )
                }

                Button {
                    showGenreSheet = true
                } label: {
                    Label("Genres", systemImage: "books.vertical")
                }

                Button {
                    playerVM.discoverRandomBook()
                } label: {
                    Label("Discover", systemImage: "shuffle")
                }

                Button {
                    showSortSheet = true
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }

                Button {
                    showSettingsSheet = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

/// A subfolder section for grouped display
private struct SubfolderSection {
    let name: String
    let books: [Book]
}

/// Bottom sheet for choosing sort order, matching the genre sheet style
struct SortSheet: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(LibraryViewModel.SortOrder.allCases, id: \.self) { order in
                    Button {
                        libraryVM.sortOrder = order
                        dismiss()
                    } label: {
                        HStack {
                            Text(order.rawValue)
                                .foregroundStyle(.primary)
                            Spacer()
                            if libraryVM.sortOrder == order {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sort By")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A pill-shaped filter chip
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? AppColors.accent : AppColors.secondaryFill)
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Manage Libraries Sheet

/// Bottom sheet for adding, removing, and switching libraries
struct ManageLibrariesSheet: View {
    @EnvironmentObject var appVM: AppViewModel
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showAddLibrarySheet = false
    @State private var libraryToDelete: Library? = nil

    var body: some View {
        NavigationStack {
            List {
                // Library rows
                ForEach(appVM.allLibraries, id: \.objectID) { library in
                    Button {
                        // MainTabView reloads and syncs when the active library changes
                        appVM.switchToLibrary(library)
                        dismiss()
                    } label: {
                        HStack {
                            if library.id == appVM.activeLibraryId {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                                    .fontWeight(.semibold)
                            }
                            Text(library.displayName)
                                .foregroundStyle(.primary)
                                .fontWeight(library.id == appVM.activeLibraryId ? .semibold : .regular)
                            Spacer()
                            Text("\(library.bookCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    // Map offset to library and trigger confirmation
                    let libraries = appVM.allLibraries
                    if let index = offsets.first, index < libraries.count {
                        libraryToDelete = libraries[index]
                    }
                }

                // Add Library button
                Button {
                    showAddLibrarySheet = true
                } label: {
                    Label("Add Library", systemImage: "plus")
                }
            }
            .navigationTitle("Manage Libraries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Remove \(libraryToDelete?.displayName ?? "Library")?",
                isPresented: Binding(
                    get: { libraryToDelete != nil },
                    set: { if !$0 { libraryToDelete = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { libraryToDelete = nil }
                Button("Remove", role: .destructive) {
                    if let library = libraryToDelete {
                        appVM.removeLibrary(library)
                        libraryToDelete = nil
                        // If no libraries left, dismiss the sheet (app goes to folder picker)
                        if appVM.allLibraries.isEmpty {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This library and all its books will be removed from your device.")
            }
            .sheet(isPresented: $showAddLibrarySheet) {
                NavigationStack {
                    FolderPickerView(driveService: libraryVM.driveService)
                }
            }
        }
    }
}
