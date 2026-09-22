import Foundation
import Observation

/// One saved server: a label, where to connect, and the player's own login for
/// it. The password is stored only if the user ticks `savePassword`, in
/// UserDefaults rather than the Keychain: acceptable for the developer's own
/// LAN server; move it to the Keychain before shipping to other users.
struct ServerProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var host: String
    var port: Int
    var playerName: String
    var savePassword: Bool = false
    var password: String = ""
}

/// The launcher's favorites: a list of servers persisted to UserDefaults, plus
/// which one is selected. `activate` writes a chosen profile into the `vrdev.*`
/// keys WorldSession reads when it connects.
@Observable
final class ServerStore {
    private(set) var profiles: [ServerProfile] = []
    var selectedID: UUID?

    private let profilesKey = "vrdev.servers"
    private let selectedKey = "vrdev.selectedServer"

    init() { load() }

    var selected: ServerProfile? { profiles.first { $0.id == selectedID } }

    func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: profilesKey),
           let list = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = list
        }
        if profiles.isEmpty {
            // Always keep at least the built-in dev server so the list isn't empty.
            profiles = [ServerProfile(label: "Dev server",
                                      host: WorldSession.defaultHost,
                                      port: Int(WorldSession.port),
                                      playerName: WorldSession.playerName)]
        }
        if let s = d.string(forKey: selectedKey), let uid = UUID(uuidString: s),
           profiles.contains(where: { $0.id == uid }) {
            selectedID = uid
        } else {
            selectedID = profiles.first?.id
        }
    }

    func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) { d.set(data, forKey: profilesKey) }
        d.set(selectedID?.uuidString, forKey: selectedKey)
    }

    /// Add a new profile or update an existing one (matched by id), select it.
    func upsert(_ p: ServerProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p }
        else { profiles.append(p) }
        selectedID = p.id
        save()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedID == id { selectedID = profiles.first?.id }
        save()
    }

    /// Push a profile into the keys the live session reads at connect time. Only
    /// overwrites the saved password when the profile carries one, so an unsaved
    /// login keeps the stable generated password (the server rejects empty ones).
    func activate(_ p: ServerProfile) {
        let d = UserDefaults.standard
        d.set(p.host, forKey: "vrdev.host")
        d.set(p.port, forKey: "vrdev.port")
        d.set(p.playerName, forKey: "vrdev.playerName")
        if p.savePassword && !p.password.isEmpty { d.set(p.password, forKey: "vrdev.password") }
        selectedID = p.id
        save()
    }
}
