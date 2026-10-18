import SwiftUI

/// Bottom sheet showing genres as visual cards with cover art collages in a 2-column grid
struct GenreBrowseSheet: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    /// Total non-hidden book count for the "All Genres" card
    private var totalBookCount: Int {
        libraryVM.books.filter { !$0.isHidden }.count
    }

    /// Cover images for the "All Genres" card — grabs from across all genres
    private var allGenresCovers: [UIImage] {
        var covers: [UIImage] = []
        for genre in libraryVM.availableGenres {
            let genreCovers = libraryVM.coversForGenre(genre.name, limit: 1)
            covers.append(contentsOf: genreCovers)
            if covers.count >= 4 { break }
        }
        return Array(covers.prefix(4))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    // "All Genres" card at top-left
                    Button {
                        libraryVM.selectedGenre = nil
                        dismiss()
                    } label: {
                        GenreCardView(
                            genre: "All Genres",
                            bookCount: totalBookCount,
                            covers: allGenresCovers,
                            isSelected: libraryVM.selectedGenre == nil
                        )
                    }
                    .buttonStyle(.plain)

                    // Individual genre cards
                    ForEach(libraryVM.availableGenres, id: \.name) { genre in
                        Button {
                            libraryVM.selectedGenre = genre.name
                            dismiss()
                        } label: {
                            GenreCardView(
                                genre: genre.name,
                                bookCount: genre.count,
                                covers: libraryVM.coversForGenre(genre.name),
                                isSelected: libraryVM.selectedGenre == genre.name
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .navigationTitle("Genres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
