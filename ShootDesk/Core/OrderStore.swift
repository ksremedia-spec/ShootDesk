import Foundation

/// Keeps every Aryeo order on the phone so the app opens instantly, then freshens it from Aryeo.
/// - Quick refresh (every open, pull-to-refresh, every few minutes while open): newest 100 orders, merged in.
/// - Full sync (first launch, then at most twice a day): every order, so old changes are picked up too.
public final class OrderStore {
    public private(set) var orders: [Order] = []
    public private(set) var lastQuick: Date?
    public private(set) var lastFull: Date?

    private let fileURL: URL
    private let metaURL: URL

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("orders.json")
        metaURL = directory.appendingPathComponent("sync.json")
    }

    private struct Meta: Codable { var lastQuick: Date?; var lastFull: Date? }

    public func loadFromDisk() {
        if let d = try? Data(contentsOf: fileURL), let o = try? AryeoJSON.decoder().decode([Order].self, from: d) {
            orders = o
        }
        if let d = try? Data(contentsOf: metaURL), let m = try? JSONDecoder().decode(Meta.self, from: d) {
            lastQuick = m.lastQuick; lastFull = m.lastFull
        }
    }

    private func save() {
        if let d = try? AryeoJSON.encoder().encode(orders) { try? d.write(to: fileURL, options: .atomic) }
        if let d = try? JSONEncoder().encode(Meta(lastQuick: lastQuick, lastFull: lastFull)) { try? d.write(to: metaURL, options: .atomic) }
    }

    public var needsFullSync: Bool {
        guard let f = lastFull, !orders.isEmpty else { return true }
        return Date().timeIntervalSince(f) > 12 * 3600
    }

    /// Replaces orders with the same id and adds new ones; keeps everything newest first.
    public func merge(_ fresh: [Order]) {
        var byID: [String: Order] = [:]
        for o in orders { byID[o.id] = o }
        for o in fresh { byID[o.id] = o }
        orders = byID.values.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    /// Refreshes from Aryeo. Returns true if anything was fetched.
    @discardableResult
    public func refresh(using client: AryeoClient, forceFull: Bool = false) async throws -> Bool {
        if forceFull || needsFullSync {
            let all = try await client.allOrders()
            orders = all.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            lastFull = Date(); lastQuick = Date()
        } else {
            merge(try await client.recentOrders(count: 100))
            lastQuick = Date()
        }
        save()
        return true
    }

    /// The newest 100 orders only, never a full sync. For the short background window iOS gives the app.
    public func quickRefresh(using client: AryeoClient) async throws {
        merge(try await client.recentOrders(count: 100))
        lastQuick = Date()
        save()
    }
}
