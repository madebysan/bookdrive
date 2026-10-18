import SwiftUI

/// A visual card for the genre browse sheet — shows a cover art collage, genre name, and book count.
struct GenreCardView: View {
    let genre: String
    let bookCount: Int
    let covers: [UIImage]
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover art collage
            coverCollage
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                )

            // Genre name and book count
            VStack(alignment: .leading, spacing: 2) {
                Text(genre)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text("\(bookCount) \(bookCount == 1 ? "book" : "books")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cover Collage Layouts

    /// One collage cell: takes the space the layout offers and crops the cover to it.
    /// A bare fill image reports its scaled-up size, which pushed two-cover cards wider than their column.
    private func tile(_ image: UIImage) -> some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
    }

    @ViewBuilder
    private var coverCollage: some View {
        switch covers.count {
        case 0:
            // Placeholder icon
            Rectangle()
                .fill(Color(.secondarySystemFill))
                .overlay {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }

        case 1:
            // Single cover fills the card
            tile(covers[0])

        case 2:
            // Side by side
            HStack(spacing: 2) {
                tile(covers[0])
                tile(covers[1])
            }

        case 3:
            // 1 large on the left + 2 stacked on the right
            HStack(spacing: 2) {
                tile(covers[0])
                    .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    tile(covers[1])
                    tile(covers[2])
                }
                .frame(maxWidth: .infinity)
            }

        default:
            // 2x2 grid (4+ covers, use first 4)
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    tile(covers[0])
                    tile(covers[1])
                }
                HStack(spacing: 2) {
                    tile(covers[2])
                    tile(covers[3])
                }
            }
        }
    }
}
