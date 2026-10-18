import Foundation

// Raw shapes returned by Aryeo's developer API (api.aryeo.com/v1).
// Field names were checked against real responses from Kyle's account on Oct 15, 2026.
// Every field is optional so one missing value never breaks the whole sync.

public struct AryeoPage<T: Decodable>: Decodable {
    public let data: [T]
    public let meta: PageMeta?
}

public struct PageMeta: Decodable {
    public let currentPage: Int?
    public let lastPage: Int?
    public let total: Int?
}

public struct Order: Codable, Identifiable, Hashable {
    public let id: String
    public let number: Int?
    public let status: String?
    public let orderStatus: String?
    public let fulfillmentStatus: String?
    public let paymentStatus: String?
    public let createdAt: String?
    public let fulfilledAt: String?
    public let isGhost: Bool?
    public let totalAmount: Int?
    public let balanceAmount: Int?
    public let internalNotes: String?
    public let customer: Customer?
    public let listing: Listing?
    public let items: [OrderItem]?
    public let appointments: [Appointment]?

    public init(id: String, number: Int?, status: String?, orderStatus: String?, fulfillmentStatus: String?,
                paymentStatus: String?, createdAt: String?, fulfilledAt: String?, isGhost: Bool?,
                totalAmount: Int?, balanceAmount: Int?, internalNotes: String?, customer: Customer?,
                listing: Listing?, items: [OrderItem]?, appointments: [Appointment]?) {
        self.id = id; self.number = number; self.status = status; self.orderStatus = orderStatus
        self.fulfillmentStatus = fulfillmentStatus; self.paymentStatus = paymentStatus
        self.createdAt = createdAt; self.fulfilledAt = fulfilledAt; self.isGhost = isGhost
        self.totalAmount = totalAmount; self.balanceAmount = balanceAmount; self.internalNotes = internalNotes
        self.customer = customer; self.listing = listing; self.items = items; self.appointments = appointments
    }
}

public struct Customer: Codable, Hashable {
    public let id: String?
    public let name: String?
    public let email: String?
    public let phone: String?
    public let type: String?
}

public struct Listing: Codable, Hashable {
    public let id: String?
    public let address: Address?
    public let images: [ListingImage]?
    public let deliveryStatus: String?
    public let thumbnailUrl: String?
    public let largeThumbnailUrl: String?
}

public struct ListingImage: Codable, Hashable, Identifiable {
    public let id: String?
    public let thumbnailUrl: String?
    public let largeUrl: String?
    public let originalUrl: String?
    public let caption: String?
    public let index: Int?

    public var stableID: String { id ?? largeUrl ?? originalUrl ?? UUID().uuidString }
}

/// A delivered video. Aryeo only includes these when a listing is fetched on its own
/// (orders carry photos but leave videos and floor plans empty), so the app loads them per listing.
public struct ListingVideo: Codable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let duration: Int?
    public let thumbnailUrl: String?
    public let downloadUrl: String?   // full-quality .mov
    public let playbackUrl: String?   // streaming version for watching in the app
    public let shareUrl: String?

    /// "1:13"
    public var durationLabel: String? {
        guard let d = duration, d > 0 else { return nil }
        return String(format: "%d:%02d", d / 60, d % 60)
    }
}

public struct FloorPlan: Codable, Hashable, Identifiable {
    public let id: String
    public let title: String?
    public let index: Int?
    public let originalUrl: String?
    public let largeUrl: String?
    public let thumbnailUrl: String?
}

/// Everything delivered for one listing.
public struct ListingMedia: Hashable {
    public let images: [ListingImage]
    public let videos: [ListingVideo]
    public let floorPlans: [FloorPlan]

    public init(images: [ListingImage], videos: [ListingVideo], floorPlans: [FloorPlan]) {
        self.images = images.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        self.videos = videos
        self.floorPlans = floorPlans.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    public var isEmpty: Bool { images.isEmpty && videos.isEmpty && floorPlans.isEmpty }
}

public struct AryeoItem<T: Decodable>: Decodable {
    public let data: T
}

public struct Address: Codable, Hashable {
    public let unparsedAddress: String?
    public let unparsedAddressPartOne: String?
    public let city: String?
    public let stateOrProvince: String?
    public let postalCode: String?
    public let latitude: Double?
    public let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case unparsedAddress, unparsedAddressPartOne, city, stateOrProvince, postalCode, latitude, longitude
    }

    public init(unparsedAddress: String?, unparsedAddressPartOne: String?, city: String?, stateOrProvince: String?,
                postalCode: String?, latitude: Double?, longitude: Double?) {
        self.unparsedAddress = unparsedAddress; self.unparsedAddressPartOne = unparsedAddressPartOne
        self.city = city; self.stateOrProvince = stateOrProvince; self.postalCode = postalCode
        self.latitude = latitude; self.longitude = longitude
    }

    // Aryeo sends coordinates as numbers today; accept strings too so a format change can't break sync.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unparsedAddress = try? c.decodeIfPresent(String.self, forKey: .unparsedAddress)
        unparsedAddressPartOne = try? c.decodeIfPresent(String.self, forKey: .unparsedAddressPartOne)
        city = try? c.decodeIfPresent(String.self, forKey: .city)
        stateOrProvince = try? c.decodeIfPresent(String.self, forKey: .stateOrProvince)
        postalCode = try? c.decodeIfPresent(String.self, forKey: .postalCode)
        latitude = Address.flexibleDouble(c, .latitude)
        longitude = Address.flexibleDouble(c, .longitude)
    }

    private static func flexibleDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

public struct OrderItem: Codable, Hashable {
    public let id: String?
    public let title: String?
    public let quantity: Int?
    public let amount: Int?
    public let isCanceled: Bool?
}

public struct Appointment: Codable, Hashable {
    public let id: String?
    public let title: String?
    public let description: String?
    public let startAt: String?
    public let endAt: String?
    public let duration: Int?
    public let status: String?
}

public enum AryeoJSON {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}
