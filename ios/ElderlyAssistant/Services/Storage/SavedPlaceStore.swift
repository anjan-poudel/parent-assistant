import Foundation

/// A user-saved place the voice navigation pipeline can drive to
/// (directions task, 2026-09-07).
///
/// Two categories:
///  - `.home` — one of the user's own residences ("मेरो घर", "गाउँको घर").
///    Exactly ONE of these is the default home at any time (while at least
///    one `.home` place exists), and "take me home" / "मलाई घर लैजाऊ"
///    navigates to it.
///  - `.important` — anywhere else worth a saved route ("नजिकको अस्पताल",
///    "बिहानको बजार"…), reachable by name ("अस्पताल लैजाऊ").
///
/// `address` is free-form text — whatever the user typed in the editor
/// ("बूढानीलकण्ठ, काठमाडौं ९"). The navigation pipeline forward-geocodes
/// it at request time and degrades to an address-string Maps deep link
/// when geocoding fails, so the text is never parsed by this store.
///
/// Stored encrypted via `EncryptedLocalStorage` (Keychain, Data Protection
/// Complete — constitution §Security), exactly like `FamilyContactStore`.
/// The store is unversioned; an optional field IS its migration, so the
/// custom decoder reads a missing key as its default.
struct SavedPlace: Codable, Identifiable, Equatable {
    enum Category: String, Codable {
        /// One of the user's own residences.
        case home
        /// Any other important place (hospital, market, temple…).
        case important
    }

    let id: UUID
    var name: String
    /// Free-form address text. The Settings editor requires a non-empty
    /// address; the store tolerates empties and the navigation candidate
    /// list filters them out.
    var address: String
    var category: Category
    /// True when this `.home` place is THE home "take me home" drives to.
    /// Non-`.home` places can never carry it (enforced at init and on
    /// every store read/write).
    var isDefaultHome: Bool

    init(id: UUID = UUID(), name: String, address: String,
         category: Category = .important, isDefaultHome: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.category = category
        // A non-home place can never be the default home — normalize at
        // the model boundary so a hand-built value can't smuggle the flag.
        self.isDefaultHome = isDefaultHome && category == .home
    }

    /// Custom decode — the unversioned store's migration pattern: a
    /// payload written before `category`/`isDefaultHome` existed (or any
    /// hand-edited value) loads with the defaults instead of failing the
    /// whole store read. `category` is a raw-value enum, so an unknown
    /// raw value would throw — `try?` turns that into `.important` too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = (try? container.decode(String.self, forKey: .address)) ?? ""
        category = (try? container.decode(Category.self, forKey: .category)) ?? .important
        isDefaultHome = ((try? container.decodeIfPresent(Bool.self, forKey: .isDefaultHome)) ?? false)
            && category == .home
    }
}

/// Persists the saved-places list (directions task, 2026-09-07). A
/// `FamilyContactStore` clone: same `EncryptedLocalStorage` shape, same
/// read/write/remove surface, plus the default-home bookkeeping the
/// navigation feature depends on.
///
/// Default-home rules:
///  - HARD invariant, enforced on every read AND write: at most one
///    place carries `isDefaultHome`, and only a `.home` place can carry
///    it. Legacy/hand-edited payloads self-heal through `load()`.
///  - SOFT invariant, maintained by the MUTATION paths (never invented
///    by a plain read): while at least one `.home` place exists, exactly
///    one of them is the default. The first `.home` ever added is
///    auto-promoted (so "take me home" works out of the box); an
///    explicitly toggled new/edited home beats an existing default;
///    removing or recategorizing the current default auto-promotes the
///    next `.home`. Only when the LAST `.home` is gone is there no
///    default — the router then speaks the honest `directions.noHome`.
final class SavedPlaceStore {

    /// How many places the store accepts. Small and curated — voice
    /// disambiguation prompts stay short for an elderly user.
    static let maxPlaces = 20
    private static let storageKey = "places.saved"

    private let storage: EncryptedLocalStorage

    init(storage: EncryptedLocalStorage) {
        self.storage = storage
    }

    // MARK: - Read / write

    /// The stored places with the hard invariant enforced (at most one
    /// default, only `.home` places can hold it).
    func load() -> [SavedPlace] {
        guard case .success(let places) = storage.read(
            key: Self.storageKey, type: [SavedPlace].self
        ) else { return [] }
        return Self.hardNormalized(places)
    }

    @discardableResult
    func save(_ places: [SavedPlace]) -> Bool {
        switch storage.write(key: Self.storageKey, value: Self.hardNormalized(places)) {
        case .success: return true
        case .failure: return false
        }
    }

    // MARK: - Mutations

    /// Appends a place. Rejected past `maxPlaces`. Default-home handling:
    /// the FIRST `.home` ever stored is auto-promoted to default; a
    /// `.home` added with `isDefaultHome` true explicitly demotes any
    /// current default (the user's choice wins over an older default).
    @discardableResult
    func add(_ place: SavedPlace) -> Bool {
        var places = load()
        guard places.count < Self.maxPlaces else { return false }
        var incoming = place
        if incoming.category == .home && incoming.isDefaultHome {
            for i in places.indices { places[i].isDefaultHome = false }
        } else if incoming.category == .home,
                  !places.contains(where: { $0.category == .home }) {
            incoming.isDefaultHome = true   // first home auto-promotes
        }
        places.append(incoming)
        return save(places)
    }

    /// Removes the place with `id`. When the current default goes, the
    /// first remaining `.home` is auto-promoted (nothing is promoted when
    /// only `.important` places remain).
    @discardableResult
    func remove(id: UUID) -> Bool {
        var places = load()
        places.removeAll { $0.id == id }
        if !places.contains(where: { $0.isDefaultHome }),
           let firstHome = places.firstIndex(where: { $0.category == .home }) {
            places[firstHome].isDefaultHome = true
        }
        return save(places)
    }

    /// Replaces the stored place with `place`'s id (the Settings editor's
    /// save). A `.home` saved with `isDefaultHome` true becomes the
    /// default (any previous default is demoted — the user's toggle wins).
    /// Saving the current default demoted (flag false) or recategorized
    /// to `.important` auto-promotes the first remaining `.home`.
    @discardableResult
    func update(_ place: SavedPlace) -> Bool {
        var places = load()
        guard let index = places.firstIndex(where: { $0.id == place.id }) else { return false }
        var incoming = place
        if incoming.category == .home && incoming.isDefaultHome {
            // The user's toggle wins: demote any current default, then
            // this place carries the flag.
            for i in places.indices { places[i].isDefaultHome = false }
            incoming.isDefaultHome = true
        }
        places[index] = incoming
        // A demoted/recategorized save of the current default must not
        // leave the list default-less while `.home` places remain —
        // promote the first remaining home.
        if !places.contains(where: { $0.isDefaultHome }),
           let firstHome = places.firstIndex(where: { $0.category == .home }) {
            places[firstHome].isDefaultHome = true
        }
        return save(places)
    }

    /// The `.home` place "take me home" drives to — nil when the user has
    /// no `.home` place saved (the router then speaks the honest
    /// `directions.noHome` fallback).
    var defaultHome: SavedPlace? {
        load().first { $0.isDefaultHome }
    }

    /// Makes the `.home` place with `id` the default home. Returns false
    /// when no such place exists or it is not a `.home` place (an
    /// `.important` place can never be "home").
    @discardableResult
    func setDefaultHome(id: UUID) -> Bool {
        var places = load()
        guard let index = places.firstIndex(where: { $0.id == id }),
              places[index].category == .home else { return false }
        for i in places.indices {
            places[i].isDefaultHome = places[i].id == id
        }
        return save(places)
    }

    // MARK: - Hard invariant

    /// Enforces the hard default-home invariant on any list: non-`.home`
    /// places never carry `isDefaultHome`, and at most one `.home` does
    /// (when several claim it, the first keeps it). Deliberately does NOT
    /// invent a default where none exists — auto-promotion is owned by
    /// the mutation paths above, which know the user's intent.
    private static func hardNormalized(_ places: [SavedPlace]) -> [SavedPlace] {
        var result = places
        var defaultSeen = false
        for i in result.indices {
            if result[i].category == .home && result[i].isDefaultHome && !defaultSeen {
                defaultSeen = true
            } else {
                result[i].isDefaultHome = false
            }
        }
        return result
    }
}
