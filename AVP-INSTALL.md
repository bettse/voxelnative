# Installing VoxelNative on Apple Vision Pro

VoxelNative is a native Luanti (formerly Minetest) client for Apple Vision Pro, written in Swift and Metal. It speaks the Luanti network protocol directly, so an unmodified Luanti server hands it the whole game, and it renders the world per eye in full immersion with Compositor Services. It is built and tested against [VoxeLibre](https://github.com/VoxeLibre/VoxeLibre), but connects to any Luanti server.

## What you need

- Apple Vision Pro on visionOS 26 or later
- A Luanti server you can reach (VoxeLibre is the one it's tested with; a local dev server works)
- Optional, for the best experience: PlayStation VR2 Sense controllers. A Bluetooth keyboard also works, with your gaze aiming and a pinch to click. Mice and trackpads don't reach a fully immersive app on visionOS, so they aren't supported.
- To build from source: a Mac with Xcode 26 and `xcodegen` on your `PATH`

## Your game files

There's nothing to bring. This app ships no game content: the game's textures, sounds, models and Lua come from the server you connect to, under their own licenses. On the headset, enter your server's address on the launcher screen; there's no built-in default.

To run your own local server, `tools/server.sh` starts a VoxeLibre dedicated server on port 30000. It expects the Luanti app at `/Applications/luanti.app` with VoxeLibre installed, and passes `tools/server.conf` as its config, a local file that is gitignored and so isn't in a fresh checkout.

## Install with TestFlight

Join the public beta: <https://testflight.apple.com/join/n6sD7wYX>

## Build from source

From a checkout of this repository, all from `native/`:

1. Put your Apple Developer team in a `native/.env` file, which is gitignored:

   ```sh
   DEVELOPMENT_TEAM=YOUR_TEAM_ID
   ```

   `native/project.yml` ships without a team, and the bundle identifier is `dev.ericbetts.voxelnative`. If Xcode reports that it isn't available to your team, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
2. Pair your Vision Pro with Xcode, then build and install:

   ```sh
   ./deploy.sh
   ```

   It regenerates `VoxelNative.xcodeproj` from `project.yml` with XcodeGen, builds the Release configuration for the paired headset, and installs it. It never launches the app: open it from the headset yourself. If the app looks like it's running, it skips the install so a session isn't cut off; pass `--force` to install anyway.

To work in Xcode instead, run `xcodegen generate` in `native/`, open `VoxelNative.xcodeproj`, set your team, and run on your Vision Pro.

`./sim.sh` builds for the visionOS Simulator, launches it, and screenshots the immersive view; no headset needed. `make help` lists the other helpers.

## Notes

- **Controls:** you look around and aim with your head. With the Sense controllers, the left stick walks and the right stick turns; the right trigger digs and the right grip places or uses; Circle opens the inventory and Options the pause menu. With a keyboard, WASD walks, F digs, R places, I opens the inventory and Esc pauses. The full list is on the [controls page](https://bettse.github.io/voxelnative/controls.html).
- The PS VR2 controllers give 6DoF tracking, buttons, sticks and haptics on visionOS; precision haptics and adaptive triggers don't come through.
- The README notes that much of the code was written with an AI coding assistant, and that it is still a work in progress and rough in places. Bug reports and fixes are welcome on [GitHub](https://github.com/bettse/voxelnative/issues).
