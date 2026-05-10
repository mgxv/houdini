// User-supplied overrides on the gate-driven hide decision. Read
// from `apps.json`; written by `houdini deny`.

import Foundation

struct AppOverrides: Equatable {
    var deny: Set<String>

    static let empty = AppOverrides(deny: [])
}

extension AppOverrides: Codable {
    private enum CodingKeys: String, CodingKey { case deny }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let deny = try c.decodeIfPresent([String].self, forKey: .deny) ?? []
        self.init(deny: Set(deny))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deny.sorted(), forKey: .deny)
    }
}

enum AppOverridesState {
    private static func url() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false,
        ) else { return nil }
        return appSupport
            .appendingPathComponent(Log.subsystem, isDirectory: true)
            .appendingPathComponent("apps.json")
    }

    static func read() -> AppOverrides {
        guard let url = url() else { return .empty }
        return read(at: url)
    }

    static func read(at url: URL) -> AppOverrides {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(AppOverrides.self, from: data)
        else { return .empty }
        return parsed
    }

    static func write(_ overrides: AppOverrides) throws {
        guard let url = url() else {
            throw NSError(
                domain: "AppOverridesState",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not resolve apps.json path"],
            )
        }
        try write(overrides, to: url)
    }

    static func write(_ overrides: AppOverrides, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(overrides)
        try data.write(to: url, options: .atomic)
    }
}
