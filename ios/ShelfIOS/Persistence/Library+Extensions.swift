import Foundation
import CoreData

// Convenience accessors for the Core Data Library entity
extension Library {

    /// Display name — falls back to "My Library" if no custom name is set
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return "My Library"
    }

    /// Number of books in this library
    var bookCount: Int {
        (books as? Set<Book>)?.count ?? 0
    }
}
