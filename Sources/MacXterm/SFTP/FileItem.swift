import Foundation

/// Элемент удалённого каталога.
struct FileItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case dir, file, link, other }

    var name: String
    var path: String
    var kind: Kind
    var linkToDir = false
    var size: Int64 = 0
    var mtime: Date?
    var mode: Int = 0
    var owner: String = ""

    var id: String { path }
    var isDir: Bool { kind == .dir || (kind == .link && linkToDir) }
    var isHidden: Bool { name.hasPrefix(".") }
    var ext: String { (name as NSString).pathExtension }

    var permString: String {
        let chars = Array("rwxrwxrwx")
        return String((0..<9).map { mode & (1 << (8 - $0)) != 0 ? chars[$0] : "-" })
    }
    var octalMode: String { String(mode & 0o7777, radix: 8) }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : (dir.hasSuffix("/") ? dir + name : dir + "/" + name)
    }

    static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    /// Строка GNU find: `%y\t%Y\t%s\t%T@\t%m\t%u\t%f`.
    static func parseFind(_ line: Substring, dir: String) -> FileItem? {
        let f = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
        guard f.count == 7 else { return nil }
        let name = String(f[6])
        guard name != "." && name != ".." && !name.isEmpty else { return nil }
        let kind: Kind = switch f[0] { case "d": .dir; case "f": .file; case "l": .link; default: .other }
        return FileItem(name: name, path: join(dir, name), kind: kind, linkToDir: f[1] == "d",
                        size: Int64(f[2]) ?? 0, mtime: Double(f[3]).map { Date(timeIntervalSince1970: $0) },
                        mode: Int(f[4], radix: 8) ?? 0, owner: String(f[5]))
    }

    /// Строка `ls -laL` (fallback для BusyBox/BSD).
    static func parseLS(_ line: Substring, dir: String) -> FileItem? {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count == 9, let first = parts[0].first, "-dlcbps".contains(first) else { return nil }
        var name = String(parts[8])
        if first == "l", let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
        guard name != "." && name != ".." else { return nil }
        let kind: Kind = switch first { case "d": .dir; case "-": .file; case "l": .link; default: .other }
        return FileItem(name: name, path: join(dir, name), kind: kind, size: Int64(parts[4]) ?? 0,
                        mode: modeBits(String(parts[0].dropFirst())), owner: String(parts[2]))
    }

    private static func modeBits(_ s: String) -> Int {
        let c = Array(s.prefix(9))
        guard c.count == 9 else { return 0 }
        var m = 0
        for i in 0..<9 where c[i] != "-" && c[i] != "S" && c[i] != "T" { m |= 1 << (8 - i) }
        if c[2] == "s" || c[2] == "S" { m |= 0o4000 }
        if c[5] == "s" || c[5] == "S" { m |= 0o2000 }
        if c[8] == "t" || c[8] == "T" { m |= 0o1000 }
        return m
    }
}
