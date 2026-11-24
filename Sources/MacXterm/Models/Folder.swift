import Foundation

struct Folder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var expanded: Bool = true
}
