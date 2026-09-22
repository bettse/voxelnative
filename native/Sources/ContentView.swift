import SwiftUI

/// The 2D startup window: pick a saved server (favorites), edit its login, save
/// the password, tune the sound, then Connect to open the immersive world. The
/// app boots here on device and in the sim; the world opens only on Connect.
/// The headless sim loop (sim.sh) passes `-vrdev.autoConnect 1` to connect
/// without a tap so it can still screenshot the world.
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var store = ServerStore()
    @State private var connecting = false
    // The server editor (host/port/name/password) lives in a sheet now, so the
    // launch menu is just the favorites + status; "Add server" / the pencil
    // open it. Keeps the menu uncluttered (Eric: simplify the launch menu).
    @State private var showEditor = false

    // Editor fields for the selected/new server. editID is nil for an unsaved
    // one-off (typed in but not added to favorites).
    @State private var editID: UUID?
    // Which saved server the Play button will launch. Its own source of truth,
    // not editID (which only tracks what the editor sheet has open): tapping a
    // row selects, Play connects (#353).
    @State private var selectedID: UUID?
    @State private var label = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var playerName = ""
    @State private var password = ""
    @State private var savePassword = false

    // Sound mix, seeded from saved settings; edits write back to VolumeSettings.
    @State private var volMaster = VolumeSettings.shared.master
    @State private var volMusic = VolumeSettings.shared.music
    @State private var volSfx = VolumeSettings.shared.sfx
    @State private var viewBlocks = Double(ViewSettings.shared.blocks)   // view distance (#161)

    // Testing mode: a note field for jotting bugs in-headset with the AVP
    // keyboard; notes are appended to Documents/bug-notes.txt so they can be
    // pulled alongside native.log/screenshots (#217).
    @AppStorage("vrdev.testingMode") private var testingMode = false

    // The app boots into this launcher window. On Connect it opens the immersive
    // world and DISMISSES this window (so its move/close chrome doesn't float in
    // the world); Kogane's "exit to menu" reopens it. Exit runs through
    // appModel.onExit, installed here, so it still works once this window is gone.
    var body: some View {
        launcher
            .onAppear {
                appModel.onExit = { kind in
                    Task { @MainActor in
                        appModel.stopSession()
                        if appModel.immersiveSpaceState != .closed {
                            await dismissImmersiveSpace()
                            appModel.immersiveSpaceState = .closed
                        }
                        connecting = false
                        if kind == .quit { exit(0) }
                        else { openWindow(id: appModel.launcherWindowID); print("[launcher] reopened (exit to menu)"); fflush(stdout) }   // back to the launcher
                    }
                }
            }
    }

    @State private var autoConnectStarted = false

    // MARK: - Launcher

    private var launcher: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VoxelNative").font(.largeTitle.bold())
                    Text("A Luanti client for Apple Vision Pro").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Choose a server").font(.headline).foregroundStyle(.secondary).padding(.top, 4)

                favoritesList
                statusRow
                Divider()
                displaySection
                Divider()
                soundSection
                Divider()
                advancedSection
            }
            .padding(40)
            .padding(.bottom, 40)   // room above the Play ornament
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A persistent Play button on the glass edge is the obvious primary
        // action; tapping a server row only selects it now (#353).
        .ornament(attachmentAnchor: .scene(.bottom)) {
            Button {
                if let p = playTarget { connect(to: p) }
            } label: {
                Label(connecting ? phaseText : "Play", systemImage: "play.fill")
                    .font(.title3).padding(.horizontal, 14).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(connecting || !controllerGate || playTarget == nil)
            .padding(12)
            .glassBackgroundEffect(in: .capsule)
        }
        // Let the form fill the window width instead of capping at a fixed max:
        // the window is freely resizable, so a fixed content width left an empty
        // glass band when you dragged the corner wider (#156). Filling the width
        // makes a resize self-correct (the fields/sliders widen with it).
        .glassBackgroundEffect()   // the window itself is .plain, so the panel carries its own glass
        .sheet(isPresented: $showEditor) { editorSheet }
        .onAppear {
            if editID == nil, let s = store.selected { loadFields(from: s) }
            if selectedID == nil { selectedID = store.selected?.id ?? store.profiles.first?.id }   // Play needs a target (#353)
            // Automated loop only: auto-connect to the selected server so a
            // screenshot can be taken without tapping Connect.
            if !autoConnectStarted, UserDefaults.standard.bool(forKey: "vrdev.autoConnect") {
                autoConnectStarted = true
                // Stable sim identity so the server keeps ONE account we can grant
                // privs to (creative/give for test scenes), and so relaunches
                // actually exercise the same-name reconnect path instead of dodging
                // it with a fresh name each run. Override with -vrdev.name.
                // (A fast relaunch can hit "player already connected" until the old
                // session times out -- that's a real reconnect case to handle, not
                // to paper over.)
                playerName = UserDefaults.standard.string(forKey: "vrdev.name") ?? "vrdev-sim"
                connect()
            }
        }
    }

    private var favoritesList: some View {
        VStack(spacing: 6) {
            if store.profiles.isEmpty {
                // First run / everything deleted: guide the one thing to do here.
                ContentUnavailableView {
                    Label("No servers yet", systemImage: "server.rack")
                } description: {
                    Text("Add a Luanti server to start playing.")
                } actions: {
                    Button { newServer(); showEditor = true } label: { Label("Add server", systemImage: "plus.circle") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                // Tapping a row SELECTS it (drives the radio); the Play ornament
                // launches the selected server. The pencil opens the editor sheet
                // without launching (#353).
                ForEach(store.profiles) { p in
                    HStack(spacing: 8) {
                        Button { select(p) } label: { serverRow(p) }
                            .buttonStyle(.plain)
                        Button { loadFields(from: p); showEditor = true } label: {
                            Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(.secondary)
                                .padding(10).contentShape(Rectangle())   // bigger eye+pinch target (#355)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button { newServer(); showEditor = true } label: {
                    Label("Add server", systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).foregroundStyle(.tint).padding(.top, 2)
            }
        }
    }

    /// The saved server Play launches: the selected one, else the store's active
    /// default, else the first. nil only when there are no servers at all (#353).
    private var playTarget: ServerProfile? {
        if let id = selectedID, let p = store.profiles.first(where: { $0.id == id }) { return p }
        return store.selected ?? store.profiles.first
    }

    private func select(_ p: ServerProfile) {
        selectedID = p.id
        loadFields(from: p)   // keep editor + connect() state in sync with the pick
    }

    private func serverRow(_ p: ServerProfile) -> some View {
        let selected = p.id == selectedID
        let subtitle = "\(p.host):\(String(p.port))  ·  \(p.playerName)"
        return HStack {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.label.isEmpty ? "Untitled" : p.label).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p.savePassword {
                Image(systemName: "key.fill").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Label") {
                TextField("My server", text: $label).textFieldStyle(.roundedBorder)
            }
            field("Host") {
                TextField("host or IP", text: $host).textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            field("Port") {
                TextField("30000", text: $portText).textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
            }
            field("Player") {
                TextField("player name", text: $playerName).textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            field("Password") {
                SecureField("password", text: $password).textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Toggle("Save password", isOn: $savePassword)
                .toggleStyle(.switch).frame(maxWidth: 320)
        }
    }

    /// The sim has no Sense controllers (a phantom pad at best); the automated
    /// loop must still connect, so the gate only applies on a real device.
    private var controllerGate: Bool {
        UserDefaults.standard.bool(forKey: "vrdev.autoConnect") ? true : appModel.controllersReady
    }

    private func controllerPill(_ label: String, on: Bool) -> some View {
        Label(label, systemImage: on ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(on ? Color.green : Color.secondary)
            .font(.callout)
    }

    /// Main-menu status: controller gate + connect progress/failure. Connecting
    /// itself happens by tapping a favorite (or Connect inside the editor sheet).
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("PSVR2 Sense").font(.callout).foregroundStyle(.secondary)
                controllerPill("Left", on: appModel.leftControllerOn)
                controllerPill("Right", on: appModel.rightControllerOn)
                if !controllerGate {
                    Text("turn both controllers on to connect").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if connecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)   // spinner until the world is ready
                    Text(phaseText).font(.callout).foregroundStyle(.secondary)
                }
            }
            if case .failed(let reason) = appModel.connPhase {
                Text("Couldn\u{2019}t connect: \(reason)")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
    }

    /// The server editor, in a sheet: fields + Connect / Save / Delete. Opened by
    /// "Add server" (blank) or a favorite's pencil (prefilled).
    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editID == nil ? "Add server" : "Edit server").font(.title2.bold())
            editor
            HStack(spacing: 12) {
                Button(connecting ? phaseText : "Connect") { showEditor = false; connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(connecting || host.isEmpty || playerName.isEmpty || !controllerGate)
                Button("Save") { saveFavorite(); showEditor = false }
                    .disabled(host.isEmpty || playerName.isEmpty)
                if let id = editID, store.profiles.count > 1 {
                    Button(role: .destructive) { store.delete(id); resetFromSelection(); showEditor = false } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Spacer()
                Button("Cancel") { resetFromSelection(); showEditor = false }
            }
        }
        .padding(32)
        .frame(minWidth: 520)
    }

    private func field(_ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading).foregroundStyle(.secondary)
            control()
        }
    }

    // MARK: - Editor state helpers

    private func loadFields(from p: ServerProfile) {
        editID = p.id
        label = p.label; host = p.host; portText = String(p.port)
        playerName = p.playerName; password = p.password; savePassword = p.savePassword
    }

    private func newServer() {
        editID = nil
        label = ""; host = ""; portText = "30000"; playerName = WorldSession.playerName
        password = ""; savePassword = false
    }

    private func resetFromSelection() {
        if let s = store.selected { loadFields(from: s) } else { newServer() }
    }

    private func currentProfile() -> ServerProfile {
        ServerProfile(id: editID ?? UUID(),
                      label: label.trimmingCharacters(in: .whitespaces),
                      host: host.trimmingCharacters(in: .whitespaces),
                      port: Int(portText) ?? 30000,
                      playerName: playerName.trimmingCharacters(in: .whitespaces),
                      savePassword: savePassword,
                      password: savePassword ? password : "")
    }

    private func saveFavorite() {
        var p = currentProfile()
        if p.label.isEmpty { p.label = p.host }
        store.upsert(p)
        editID = p.id
    }

    // MARK: - Connect / exit

    private var phaseText: String {
        switch appModel.connPhase {
        case .idle, .connecting: return "Connecting\u{2026}"
        case .streaming:         return "Loading world\u{2026}"
        case .reconnecting(let n): return "Reconnecting\u{2026} (\(n))"
        case .failed:            return "Failed"
        case .playing:           return "Loading world\u{2026}"
        }
    }

    private func connect() {
        let p = currentProfile()
        store.activate(p)
        appModel.worldReady = false
        appModel.connPhase = .connecting
        connecting = true
        Task { await openWorld() }
    }
    /// Launch a favorite directly: load it into the editor (so state stays in
    /// sync and a return to the launcher shows it) and connect in one action, so
    /// the user doesn't have to populate the form then hit Connect (#218).
    private func connect(to p: ServerProfile) {
        loadFields(from: p)
        connect()
    }

    // MARK: - Testing mode (in-headset bug notes)

    // Testing mode + the immersive-state readout are dev affordances, not for a
    // first-time player, so they live collapsed under "Advanced" (#354).
    private var advancedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Testing mode", isOn: $testingMode).toggleStyle(.switch).frame(maxWidth: 320)
                if testingMode {
                    // Bug capture happens in-game (the Kogane menu's "Bug note"),
                    // where you can see the bug -- a launcher text field is useless
                    // mid-session, so it's gone (#239). This just enables that option.
                    Text("Adds a \u{201C}Bug note\u{201D} option to the in-game menu (captures your view + position with the logs).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Immersive: \(String(describing: appModel.immersiveSpaceState))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced").font(.headline).foregroundStyle(.secondary)
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display").font(.headline).foregroundStyle(.secondary)
            // A stepper, not a slider: view distance is a small integer and a
            // pinch-drag slider is fiddly to land exactly in 3D space (#355).
            Stepper(value: $viewBlocks, in: Double(ViewSettings.minBlocks)...Double(ViewSettings.maxBlocks), step: 1) {
                HStack {
                    Text("View distance")
                    Spacer()
                    Text("\(Int(viewBlocks)) blocks").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 360)
            Text("Lower = fewer blocks drawn (cooler/quieter, shorter view).")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: viewBlocks) { _, v in
            let b = Int(v)
            ViewSettings.shared.blocks = b        // persisted; read at session init
            // Apply live only if we're already in-world, so moving the slider on
            // the launcher doesn't spin up the session before Connect.
            if appModel.immersiveSpaceState == .open { appModel.session.setViewDistance(b) }
        }
    }

    // MARK: - Sound

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sound").font(.headline).foregroundStyle(.secondary)
            volumeSlider("Master", value: $volMaster) { VolumeSettings.shared.master = $0 }
            volumeSlider("Music", value: $volMusic) { VolumeSettings.shared.music = $0 }
            volumeSlider("Effects", value: $volSfx) { VolumeSettings.shared.sfx = $0 }
        }
    }

    private func volumeSlider(_ label: String, value: Binding<Float>,
                              onChange: @escaping (Float) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 72, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit().lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)   // never wrap the "%" to a second line
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .onChange(of: value.wrappedValue) { _, v in onChange(v) }
    }

    private func openWorld() async {
        guard appModel.immersiveSpaceState == .closed else { return }
        appModel.immersiveSpaceState = .inTransition
        let result = await openImmersiveSpace(id: appModel.immersiveSpaceID)
        print("openImmersiveSpace(\(appModel.immersiveSpaceID)) -> \(result)"); fflush(stdout)
        if case .opened = result {
            // Keep the launcher (with its status + spinner) in front of the
            // loading world until the world is actually up, so the user never
            // stares at a bare skybox unsure it's working. If the connection
            // fails, close the immersive space and stay on the launcher with the
            // reason shown (rather than dumping them into an empty skybox).
            // No blind timeout: the phase drives the outcome, and reconnect
            // attempts cap out to `.failed("server unreachable")` on their own.
            // Safety net: if we authenticate and stream but no geometry ever
            // posts (rare), reveal the world anyway after 45s rather than
            // hanging on the launcher forever.
            let stallDeadline = Date().addingTimeInterval(45)
            while true {
                if appModel.worldReady { break }                 // world is up
                if case .failed = appModel.connPhase { break }   // give up, show reason
                if Date() >= stallDeadline { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if case .failed = appModel.connPhase {
                await dismissImmersiveSpace()
                appModel.immersiveSpaceState = .closed
                appModel.session.stop()          // stop the retry loop; the user re-taps Connect
                connecting = false
            } else {
                dismissWindow(id: appModel.launcherWindowID)   // hide the launcher while in-world
                print("[launcher] dismissed (world ready)"); fflush(stdout)
                connecting = false                             // reset so a later return to the launcher is clean
            }
        } else {
            appModel.immersiveSpaceState = .closed
            connecting = false
        }
    }
}
