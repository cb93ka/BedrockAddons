import Foundation

/// Finds the games/com.mojang folder Minecraft Bedrock keeps its packs and worlds in.
enum MinecraftFolder {
    static let markers = ["resource_packs", "behavior_packs", "minecraftWorlds", "minecraftpe"]

    /// The user may pick com.mojang itself, Minecraft's Documents, or any folder above it.
    static func resolve(_ picked: URL) -> [URL] {
        if isComMojang(picked) { return [picked] }
        for path in ["com.mojang", "games/com.mojang", "Documents/games/com.mojang"] {
            let candidate = picked.appendingPathComponent(path, isDirectory: true)
            if directoryExists(candidate) { return [candidate] }
        }
        return search(from: picked, maxDepth: 6)
    }

    /// Inside LiveContainer every app's data lives side by side in Data/Application/<id>,
    /// and the guest's home is one of those folders, so Minecraft's data is a few levels up.
    static func autoDetect() -> [URL] {
        var start = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        for _ in 0..<3 { start.deleteLastPathComponent() }
        var found = search(from: start, maxDepth: 7)
        let own = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/games/com.mojang")
        if directoryExists(own) && !found.contains(own) { found.append(own) }
        return found
    }

    static func isComMojang(_ url: URL) -> Bool {
        if url.lastPathComponent == "com.mojang" { return true }
        return markers.contains { directoryExists(url.appendingPathComponent($0)) }
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Breadth-first, without descending into any com.mojang it finds.
    private static func search(from start: URL, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        var queue: [(URL, Int)] = [(start, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 20_000 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            if dir.lastPathComponent == "com.mojang" && dir.deletingLastPathComponent().lastPathComponent == "games" {
                found.append(dir.standardizedFileURL)
                continue
            }
            guard depth < maxDepth,
                  let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for item in contents where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // .app bundles and the worlds of other games are never on the way to com.mojang.
                if item.pathExtension == "app" || item.lastPathComponent == "Library" { continue }
                queue.append((item, depth + 1))
            }
        }
        return found
    }

    /// The app that owns a com.mojang folder, shown so several Minecraft copies can be told apart.
    static func label(for url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if let i = parts.lastIndex(of: "Application"), i + 1 < parts.count {
            let id = parts[i + 1]
            return "Data/Application/\(id.prefix(8))…/games/com.mojang"
        }
        return parts.suffix(4).joined(separator: "/")
    }

    struct Stats {
        var resource = 0, behavior = 0, worlds = 0
    }

    static func stats(_ root: URL) -> Stats {
        func count(_ name: String) -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(name).path)) ?? [])
                .filter { !$0.hasPrefix(".") }.count
        }
        return Stats(resource: count("resource_packs"), behavior: count("behavior_packs"), worlds: count("minecraftWorlds"))
    }

    struct World: Identifiable, Hashable {
        let url: URL
        let name: String
        var id: String { url.lastPathComponent }
    }

    static func worlds(_ root: URL) -> [World] {
        let dir = root.appendingPathComponent("minecraftWorlds")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { directoryExists($0) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .map { url in
                let name = (try? String(contentsOf: url.appendingPathComponent("levelname.txt"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return World(url: url, name: (name?.isEmpty == false ? name! : url.lastPathComponent))
            }
    }
}
