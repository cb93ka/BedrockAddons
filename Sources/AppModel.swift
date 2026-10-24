import Foundation
import Combine

struct QueuedFile: Identifiable {
    enum Status {
        case pending
        case working
        case done([InstalledItem])
        case failed(String)
    }

    let id = UUID()
    let name: String
    let localURL: URL
    var status: Status = .pending

    var isPending: Bool {
        if case .pending = status { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var folder: URL?
    @Published var stats = MinecraftFolder.Stats()
    @Published var worlds: [MinecraftFolder.World] = []
    @Published var files: [QueuedFile] = []
    @Published var isInstalling = false
    @Published var message: String?
    @Published var folderChoices: [URL] = []

    @Published var enableGlobally = UserDefaults.standard.object(forKey: "enableGlobally") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enableGlobally, forKey: "enableGlobally") }
    }
    @Published var attachToWorlds = UserDefaults.standard.bool(forKey: "attachToWorlds") {
        didSet { UserDefaults.standard.set(attachToWorlds, forKey: "attachToWorlds") }
    }
    @Published var selectedWorlds: Set<String> = []

    private let bookmarkKey = "minecraftFolderBookmark"
    private let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("Inbox", isDirectory: true)

    init() {
        restoreFolder()
    }

    // MARK: Folder

    func autoDetect() {
        let found = MinecraftFolder.autoDetect()
        switch found.count {
        case 0:
            message = "Папку Minecraft не нашёл. Запусти Minecraft в LiveContainer хотя бы раз или выбери папку вручную."
        case 1:
            setFolder(found[0])
        default:
            folderChoices = found
        }
    }

    func pickedFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        let found = MinecraftFolder.resolve(url)
        switch found.count {
        case 0:
            message = "В «\(url.lastPathComponent)» нет games/com.mojang. Выбери папку com.mojang или любую папку выше неё."
        case 1:
            setFolder(found[0])
        default:
            folderChoices = found
        }
    }

    func setFolder(_ url: URL) {
        folder = url
        folderChoices = []
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        refreshFolder()
    }

    func refreshFolder() {
        guard let folder else { return }
        stats = MinecraftFolder.stats(folder)
        worlds = MinecraftFolder.worlds(folder)
        selectedWorlds = selectedWorlds.intersection(worlds.map(\.id))
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        guard MinecraftFolder.directoryExists(url) else { return }
        folder = url
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        refreshFolder()
    }

    // MARK: Files

    func addFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            guard AddonInstaller.archiveExtensions.contains(url.pathExtension.lowercased()) else {
                files.append(QueuedFile(name: name, localURL: url, status: .failed("Не аддон: нужен .mcpack, .mcaddon, .mcworld, .mctemplate или .zip")))
                continue
            }
            // Picked files are only readable while the picker's grant lasts, so keep a copy.
            let copy = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
                files.append(QueuedFile(name: name, localURL: copy))
            } catch {
                files.append(QueuedFile(name: name, localURL: url, status: .failed("Не удалось прочитать: \(error.localizedDescription)")))
            }
        }
    }

    func remove(at offsets: IndexSet) {
        for i in offsets { try? FileManager.default.removeItem(at: files[i].localURL.deletingLastPathComponent()) }
        files.remove(atOffsets: offsets)
    }

    func clearFinished() {
        files.removeAll { if case .done = $0.status { return true } else { return false } }
    }

    var canInstall: Bool {
        folder != nil && !isInstalling && files.contains(where: \.isPending)
    }

    // MARK: Install

    func install() {
        guard let folder else { return }
        isInstalling = true
        let jobs = files.filter(\.isPending)
        let enableGlobally = self.enableGlobally
        let targetWorlds = attachToWorlds ? worlds.filter { selectedWorlds.contains($0.id) }.map(\.url) : []

        Task {
            var installed = 0
            var failed = 0
            for job in jobs {
                setStatus(job.id, .working)
                let result: Result<[InstalledItem], Error> = await Task.detached(priority: .userInitiated) {
                    Result(catching: {
                        let installer = AddonInstaller(root: folder)
                        let items = try installer.install(file: job.localURL)
                        for item in items {
                            if enableGlobally { try installer.enableGlobally(item) }
                            for world in targetWorlds { try installer.attach(item, toWorld: world) }
                        }
                        return items
                    })
                }.value
                switch result {
                case .success(let items):
                    installed += items.count
                    setStatus(job.id, .done(items))
                    try? FileManager.default.removeItem(at: job.localURL.deletingLastPathComponent())
                case .failure(let error):
                    failed += 1
                    setStatus(job.id, .failed(error.localizedDescription))
                }
            }
            isInstalling = false
            refreshFolder()
            message = failed == 0
                ? "Готово: установлено \(installed). Перезапусти Minecraft, если он был открыт."
                : "Установлено \(installed), с ошибкой файлов: \(failed). Подробности в списке."
        }
    }

    private func setStatus(_ id: UUID, _ status: QueuedFile.Status) {
        if let i = files.firstIndex(where: { $0.id == id }) { files[i].status = status }
    }
}
