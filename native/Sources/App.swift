import ARKit
import CompositorServices
import SwiftUI

// The immersive content: a CompositorLayer driving our Metal Renderer.
struct ImmersiveSpaceContent: CompositorContent {
    var appModel: AppModel
    var body: some CompositorContent {
        CompositorLayer(configuration: self) { @MainActor layerRenderer in
            print("CompositorLayer closure: starting render loop"); fflush(stdout)
            appModel.observeLifecycle()   // clean disconnect/reconnect on app leave/return
            appModel.startSession()   // auto-connect + stream
            // Trackpad/mouse clicks reach an immersive space as spatial events,
            // not GCMouse; route them to the game input.
            layerRenderer.onSpatialEvent = { events in PointerInput.shared.handle(events) }
            Renderer.startRenderLoop(layerRenderer, appModel: appModel, arSession: ARKitSession())
        }
    }
}

// Foveation ON, layered stereo layout. This is the exact configuration Apple's
// template uses and that CompositorServices then wires to the render pass's
// rasterizationRateMap -- the step Godot's visionOS renderer got wrong.
extension ImmersiveSpaceContent: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
    }
}

@main
struct VoxelNativeApp: App {
    @State private var appModel = AppModel()

    init() { redirectStdioToFile(); clearScreenshotsIfRequested() }

    var body: some Scene {
        // .plain drops the system glass so the window can be made fully
        // invisible while you're in the immersive world (the launcher supplies
        // its own glass panel). Without this a "hidden" window still shows a
        // dark plate floating in front of the world.
        WindowGroup(id: appModel.launcherWindowID) {
            ContentView().environment(appModel)
                // Start listening for the Sense controllers HERE, on the
                // launcher: the immersive space (where this used to start)
                // doesn't exist until after Connect, so the gate never saw them.
                .onAppear { appModel.observeControllers() }
        }
        .windowStyle(.plain)
        // Open tall enough to show the whole launcher form (through the Sound
        // section) without scrolling: with .plain and no explicit size the
        // window came up short and clipped the volume sliders off the bottom
        // edge, with no obvious way to scroll or resize to them (#154).
        .defaultSize(width: 640, height: 900)
        // NOTE: do NOT tie the session to scenePhase. Opening the immersive
        // space backgrounds the 2D window, so a scenePhase .background here
        // fired stop() mid-play and thrashed connect/disconnect (killing input
        // polling too). The session starts once when the immersive space opens
        // and stays up; the reconnect retry handles drops.
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveSpaceContent(appModel: appModel)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        // Hide the system's passthrough hands/controllers so only our rendered
        // hand boxes show (otherwise the real controllers show through too).
        .upperLimbVisibility(.hidden)
        // #84: no system overlays in-world (the look-at-controller menu circle).
        .persistentSystemOverlays(DisplaySettings.shared.hideSystemOverlays ? .hidden : .visible)
    }
}
