import Foundation
import ZIPFoundation

/// Kind of content found inside an addon file and the com.mojang subfolder it goes to.
enum PackKind: String {
    case resource, behavior, skin, worldTemplate, world

    var folder: String {
        switch self {
        case .resource: return "resource_packs"
        case .behavior: return "behavior_packs"
        case .skin: return "skin_packs"
        case .worldTemplate: return "world_templates"
        case .world: return "minecraftWorlds"
        }
    }

    var title: String {
        switch self {
        case .resource: return "ресурс-пак"
        case .behavior: return "пак поведения"
        case .skin: return "скин-пак"
        case .worldTemplate: return "шаблон мира"
        case .world: return "мир"
        }
    }
}

struct InstalledItem: Identifiable {
    let id = UUID()
    let name: String
    let kind: PackKind
    let uuid: String?
    let version: [Int]
    let replaced: Bool
}

struct InstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Manifest {
    let uuid: String
    let version: [Int]
    let name: String?
    let kind: PackKind?

    static func read(_ url: URL) throws -> Manifest {
        var data = try Data(contentsOf: url)
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        // Mojang's parser tolerates comments and trailing commas, and so do many published packs.
        guard let json = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              let header = json["header"] as? [String: Any],
              let uuid = header["uuid"] as? String else {
            throw InstallError(message: "manifest.json без header.uuid")
        }
        let types = (json["modules"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }.map { $0.lowercased() }
        let kind: PackKind?
        if types.contains("world_template") {
            kind = .worldTemplate
        } else if types.contains("skin_pack") {
            kind = .skin
        } else if types.contains(where: { ["data", "script", "javascript", "client_data"].contains($0) }) {
            kind = .behavior
        } else if types.contains("resources") {
            kind = .resource
        } else {
            kind = nil
        }
        return Manifest(uuid: uuid.lowercased(), version: parseVersion(header["version"]),
                        name: header["name"] as? String, kind: kind)
    }

    /// header.version is [1, 0, 0] in format 1–2 manifests and "1.0.0" in format 3.
    static func parseVersion(_ value: Any?) -> [Int] {
        if let array = value as? [Any] {
            let numbers = array.compactMap { ($0 as? NSNumber)?.intValue }
            if !numbers.isEmpty { return numbers }
        }
        if let string = value as? String {
            let numbers = string.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if !numbers.isEmpty { return Array(numbers.prefix(3)) }
        }
        return [1, 0, 0]
    }
}

/// Unpacks addon files and copies their packs and worlds into a com.mojang folder.
final class AddonInstaller {
    static let archiveExtensions: Set<String> = ["mcpack", "mcaddon", "mcworld", "mctemplate", "zip"]

    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
    }

    func install(file: URL) throws -> [InstalledItem] {
        let work = fm.temporaryDirectory.appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try unzip(file, to: work)
        try expandNestedArchives(in: work, depth: 0)

        var items: [InstalledItem] = []
        var skipped: [String] = []
        try visit(work, items: &items, skipped: &skipped)
        if items.isEmpty {
            let reason = skipped.isEmpty ? "" : " (пропущено: \(skipped.joined(separator: ", ")))"
            throw InstallError(message: "Внутри нет ни одного пака или мира\(reason)")
        }
        return items
    }

    // MARK: Unpacking

    private func unzip(_ archiveURL: URL, to destination: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read, pathEncoding: nil)
        } catch {
            throw InstallError(message: "Не ZIP-архив или файл повреждён")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in archive {
            // Packs zipped on Windows sometimes store "\" as the path separator.
            let parts = entry.path.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").map(String.init)
                .filter { !$0.isEmpty && $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { continue }
            let target = parts.reduce(destination) { $0.appendingPathComponent($1) }
            switch entry.type {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .file:
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                _ = try archive.extract(entry, to: target)
            case .symlink:
                continue
            }
        }
    }

    /// An .mcaddon is usually a zip of .mcpack files; unpack those in place, a few levels deep.
    private func expandNestedArchives(in dir: URL, depth: Int) throws {
        guard depth < 4 else { return }
        let nested = allFiles(in: dir).filter { Self.archiveExtensions.contains($0.pathExtension.lowercased()) }
        for archive in nested {
            let target = archive.deletingPathExtension().appendingPathExtension("unpacked")
            do {
                try unzip(archive, to: target)
                try fm.removeItem(at: archive)
                try expandNestedArchives(in: target, depth: depth + 1)
            } catch {
                try? fm.removeItem(at: target)
            }
        }
    }

    // MARK: Finding packs

    private func visit(_ dir: URL, items: inout [InstalledItem], skipped: inout [String]) throws {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifestURL.path) {
            let manifest: Manifest
            do {
                manifest = try Manifest.read(manifestURL)
            } catch {
                skipped.append("\(dir.lastPathComponent): битый manifest.json")
                return
            }
            guard let kind = manifest.kind else {
                skipped.append("\(dir.lastPathComponent): неизвестный тип пака")
                return
            }
            items.append(try installPack(dir, manifest: manifest, kind: kind))
            return
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("level.dat").path) {
            items.append(try installWorld(dir))
            return
        }
        for sub in subdirectories(of: dir) where sub.lastPathComponent != "__MACOSX" {
            try visit(sub, items: &items, skipped: &skipped)
        }
    }

    // MARK: Copying

    private func installPack(_ dir: URL, manifest: Manifest, kind: PackKind) throws -> InstalledItem {
        let target = root.appendingPathComponent(kind.folder, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        let name = displayName(manifest.name, fallback: dir)
        let destination: URL
        let replaced: Bool
        if let existing = findPack(uuid: manifest.uuid, in: target) {
            try fm.removeItem(at: existing)
            destination = existing
            replaced = true
        } else {
            destination = uniqueURL(in: target, name: folderName(name))
            replaced = false
        }
        try fm.copyItem(at: dir, to: destination)
        return InstalledItem(name: name, kind: kind, uuid: manifest.uuid, version: manifest.version, replaced: replaced)
    }

    private func installWorld(_ dir: URL) throws -> InstalledItem {
        let target = root.appendingPathComponent(PackKind.world.folder, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let levelName = (try? String(contentsOf: dir.appendingPathComponent("levelname.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var destination: URL
        repeat {
            destination = target.appendingPathComponent(Self.worldID(), isDirectory: true)
        } while fm.fileExists(atPath: destination.path)
        try fm.copyItem(at: dir, to: destination)
        let name = displayName(levelName, fallback: dir)
        return InstalledItem(name: name, kind: .world, uuid: nil, version: [], replaced: false)
    }

    private func findPack(uuid: String, in folder: URL) -> URL? {
        subdirectories(of: folder).first { pack in
            (try? Manifest.read(pack.appendingPathComponent("manifest.json")))?.uuid == uuid
        }
    }

    // MARK: Activation

    /// Puts the pack on top of a world_*_packs.json / global_resource_packs.json list.
    func addReference(_ item: InstalledItem, to file: URL) throws {
        guard let uuid = item.uuid else { return }
        var list: [[String: Any]] = []
        if let data = try? Data(contentsOf: file),
           let existing = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [[String: Any]] {
            list = existing
        }
        list.removeAll { ($0["pack_id"] as? String)?.lowercased() == uuid }
        list.insert(["pack_id": uuid, "version": item.version], at: 0)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])
        try data.write(to: file, options: .atomic)
    }

    func enableGlobally(_ item: InstalledItem) throws {
        guard item.kind == .resource else { return }
        try addReference(item, to: root.appendingPathComponent("minecraftpe/global_resource_packs.json"))
    }

    func attach(_ item: InstalledItem, toWorld world: URL) throws {
        switch item.kind {
        case .resource: try addReference(item, to: world.appendingPathComponent("world_resource_packs.json"))
        case .behavior: try addReference(item, to: world.appendingPathComponent("world_behavior_packs.json"))
        default: return
        }
    }

    // MARK: Helpers

    private func displayName(_ raw: String?, fallback: URL) -> String {
        // Names like "pack.name" are localisation keys, not names.
        if let raw, !raw.isEmpty, raw != "pack.name", !raw.hasPrefix("pack.") {
            let clean = raw.replacingOccurrences(of: "§.", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return clean }
        }
        let base = fallback.lastPathComponent.replacingOccurrences(of: ".unpacked", with: "")
        return base.hasPrefix("unpack-") ? "Без названия" : base
    }

    private func folderName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return cleaned.isEmpty ? "pack" : String(cleaned.prefix(60))
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Bedrock names world folders with 12 random characters.
    private static func worldID() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in chars.randomElement()! })
    }

    private func subdirectories(of dir: URL) -> [URL] {
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func allFiles(in dir: URL) -> [URL] {
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}
