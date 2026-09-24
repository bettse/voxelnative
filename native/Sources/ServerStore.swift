import Foundation
import Observation

/// One saved server: a label, where to connect, and the player's own login for
/// it. The password is kept only if the user ticks `savePassword`, and then in
/// the Keychain (keyed by profile id), never in the UserDefaults JSON.
struct ServerProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var label: String
    var host: String
    var port: Int
    var playerName: String
    var savePassword: Bool = false
    var password: String = ""

    private enum CodingKeys: String, CodingKey { case id, label, host, port, playerName, savePassword, password }

    init(id: UUID = UUID(), label: String, host: String, port: Int, playerName: String,
         savePassword: Bool = false, password: String = "") {
        self.id = id; self.label = label; self.host = host; self.port = port
        self.playerName = playerName; self.savePassword = savePassword; self.password = password
    }

    // Decoding still reads `password` so builds that kept it in UserDefaults
    // migrate (ServerStore.load moves it to the Keychain); encoding drops it,
    // unless there's no Keychain to hold it (unsigned sim build).
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        playerName = try c.decode(String.self, forKey: .playerName)
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? false
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
        try c.encode(host, forKey: .host); try c.encode(port, forKey: .port)
        try c.encode(playerName, forKey: .playerName); try c.encode(savePassword, forKey: .savePassword)
        if !Keychain.available && savePassword { try c.encode(password, forKey: .password) }
    }
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
            var migrated = false
            for i in profiles.indices where Keychain.available {
                if !profiles[i].password.isEmpty {
                    Keychain.set(profiles[i].password, for: profiles[i].id.uuidString); migrated = true
                } else if profiles[i].savePassword {
                    profiles[i].password = Keychain.get(profiles[i].id.uuidString) ?? ""
                }
            }
            if migrated { save() }   // rewrite the JSON without the passwords
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
        for p in profiles where Keychain.available {
            if p.savePassword && !p.password.isEmpty { Keychain.set(p.password, for: p.id.uuidString) }
            else { Keychain.delete(p.id.uuidString) }
        }
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
        Keychain.delete(id.uuidString)
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
        if p.savePassword && !p.password.isEmpty {
            if !Keychain.available || !Keychain.set(p.password, for: WorldSession.activePasswordAccount) {
                d.set(p.password, forKey: WorldSession.legacyPasswordKey)
            }
        }
        selectedID = p.id
        save()
    }
}
