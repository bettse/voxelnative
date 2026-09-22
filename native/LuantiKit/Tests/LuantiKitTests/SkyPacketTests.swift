import XCTest
@testable import LuantiKit

/// Sky packets (#102): SET_SKY (both layouts), SET_SUN/MOON/STARS,
/// CLOUD_PARAMS, SET_LIGHTING parse into Client.sky and publish via onSky.
/// Wire layouts mirror Client::handleCommand_HudSetSky & co.
final class SkyPacketTests: XCTestCase {

    private func argb(_ a: Int, _ r: Int, _ g: Int, _ b: Int) -> Int { (a << 24) | (r << 16) | (g << 8) | b }
    private func c255(_ v: Int) -> Float { Float(v) / 255 }

    private func client(proto: Int = 39) -> (Client, () -> Int) {
        let c = Client(name: "t", password: "")
        c.protoVer = proto
        var fired = 0
        c.onSky = { _ in fired += 1 }
        return (c, { fired })
    }

    func testRegularSkyCarriesColourTable() {
        let (c, fired) = client()
        let w = PacketWriter()
        w.u32(argb(255, 255, 255, 255)).string16("regular")
        w.u8(0)                                              // clouds off
        w.u32(0).u32(0).string16("default")                  // fog sun/moon tint, tint type
        w.u32(argb(255, 10, 20, 30)).u32(argb(255, 40, 50, 60))      // day sky / horizon
        w.u32(argb(255, 1, 2, 3)).u32(argb(255, 4, 5, 6))            // dawn sky / horizon
        w.u32(argb(255, 70, 80, 90)).u32(argb(255, 100, 110, 120))   // night sky / horizon
        w.u32(argb(255, 9, 9, 9))                                    // indoors
        c.handleSetSky(w.data)

        XCTAssertEqual(fired(), 1)
        XCTAssertNil(c.sky.solid)
        XCTAssertFalse(c.sky.clouds)
        XCTAssertEqual(c.sky.daySky.x, c255(10), accuracy: 1e-6)
        XCTAssertEqual(c.sky.daySky.z, c255(30), accuracy: 1e-6)
        XCTAssertEqual(c.sky.dayHorizon.y, c255(50), accuracy: 1e-6)
        XCTAssertEqual(c.sky.nightSky.x, c255(70), accuracy: 1e-6)
        XCTAssertEqual(c.sky.nightHorizon.z, c255(120), accuracy: 1e-6)
    }

    func testPlainSkyIsAFlatBgcolor() {
        let (c, _) = client()
        let w = PacketWriter()
        w.u32(argb(255, 200, 10, 5)).string16("plain")
        w.u8(1).u32(0).u32(0).string16("default")
        c.handleSetSky(w.data)
        let solid = try! XCTUnwrap(c.sky.solid)
        XCTAssertEqual(solid.x, c255(200), accuracy: 1e-6)
        XCTAssertEqual(solid.y, c255(10), accuracy: 1e-6)
        XCTAssertEqual(solid.z, c255(5), accuracy: 1e-6)
        XCTAssertTrue(c.sky.clouds)
    }

    /// The optional tail after the colour table (#285): body_orbit_tilt, then
    /// fog_distance/fog_start, then fog_color. Present only when the packet is
    /// long enough, and each SET_SKY resets them to "unset".
    func testFogTailParsesAndResets() {
        let (c, _) = client()
        let w = PacketWriter()
        w.u32(argb(255, 200, 10, 5)).string16("plain")
        w.u8(1).u32(0).u32(0).string16("default")
        w.f32(0)                                   // body_orbit_tilt
        w.s16(48).f32(0.25)                        // fog_distance, fog_start
        w.u32(argb(255, 51, 8, 8))                 // fog_color (alpha 255 = set)
        c.handleSetSky(w.data)
        XCTAssertEqual(c.sky.fogDistance, 48)
        XCTAssertEqual(c.sky.fogStart, 0.25, accuracy: 1e-6)
        XCTAssertEqual(c.sky.fogColor.x, c255(51), accuracy: 1e-6)
        XCTAssertEqual(c.sky.fogColor.w, 1, accuracy: 1e-6)

        // A following SET_SKY without the tail goes back to the defaults.
        let w2 = PacketWriter()
        w2.u32(argb(255, 200, 10, 5)).string16("plain")
        w2.u8(1).u32(0).u32(0).string16("default")
        c.handleSetSky(w2.data)
        XCTAssertEqual(c.sky.fogDistance, -1)
        XCTAssertEqual(c.sky.fogStart, -1)
        XCTAssertEqual(c.sky.fogColor.w, 0)
    }

    func testLegacyProto38SkyLayout() {
        // < 39: bgcolor, type, u16 texture count + names, u8 clouds; no colours.
        let (c, fired) = client(proto: 38)
        let w = PacketWriter()
        w.u32(argb(255, 255, 255, 255)).string16("regular")
        w.u16(1).string16("sky.png").u8(1)
        c.handleSetSky(w.data)
        XCTAssertEqual(fired(), 1)
        XCTAssertNil(c.sky.solid)
        XCTAssertTrue(c.sky.clouds)
        XCTAssertEqual(c.sky.daySky, SkyParams().daySky)   // defaults kept
    }

    func testShortSkyPacketIsIgnored() {
        let (c, fired) = client()
        let w = PacketWriter()
        w.u32(argb(255, 1, 2, 3)).string16("regular")        // stops before clouds/fog/colours
        c.handleSetSky(w.data)
        XCTAssertEqual(fired(), 0)
        XCTAssertEqual(c.sky, SkyParams())
    }

    func testSunAndMoon() {
        let (c, fired) = client()
        let sun = PacketWriter()
        sun.u8(0).string16("sun.png").string16("").string16("sunrise.png").u8(1).f32(2.5)
        c.handleSetSun(sun.data)
        XCTAssertFalse(c.sky.sunVisible)
        XCTAssertEqual(c.sky.sunScale, 2.5, accuracy: 1e-6)

        let moon = PacketWriter()
        moon.u8(1).string16("moon.png").string16("").f32(0.5)
        c.handleSetMoon(moon.data)
        XCTAssertTrue(c.sky.moonVisible)
        XCTAssertEqual(c.sky.moonScale, 0.5, accuracy: 1e-6)
        XCTAssertEqual(fired(), 2)
    }

    func testStars() {
        let (c, _) = client()
        let w = PacketWriter()
        w.u8(1).u32(300).u32(argb(255, 10, 20, 30)).f32(1.5).f32(0)   // + day_opacity tail
        c.handleSetStars(w.data)
        XCTAssertTrue(c.sky.starsVisible)
        XCTAssertEqual(c.sky.starCount, 300)
        XCTAssertEqual(c.sky.starColor.y, c255(20), accuracy: 1e-6)
        XCTAssertEqual(c.sky.starScale, 1.5, accuracy: 1e-6)
    }

    func testCloudParams() {
        let (c, _) = client()
        let w = PacketWriter()
        w.f32(0.7).u32(argb(229, 1, 2, 3)).u32(argb(255, 0, 0, 0))
        w.f32(200).f32(16).f32(3).f32(-1)
        c.handleCloudParams(w.data)
        XCTAssertEqual(c.sky.cloudDensity, 0.7, accuracy: 1e-6)
        XCTAssertEqual(c.sky.cloudColor.z, c255(3), accuracy: 1e-6)
        XCTAssertEqual(c.sky.cloudHeight, 200, accuracy: 1e-6)
        XCTAssertEqual(c.sky.cloudSpeed.x, 3, accuracy: 1e-6)
        XCTAssertEqual(c.sky.cloudSpeed.y, -1, accuracy: 1e-6)
    }

    func testLightingSaturation() {
        let (c, _) = client()
        let w = PacketWriter()
        w.f32(0.3).f32(0.25)                                   // shadow_intensity, saturation
        for _ in 0..<6 { w.f32(0) }                            // exposure block
        c.handleSetLighting(w.data)
        XCTAssertEqual(c.sky.saturation, 0.25, accuracy: 1e-6)

        // A shadow-only (pre-5.7) packet leaves saturation alone.
        let (c2, _) = client()
        c2.handleSetLighting(PacketWriter().f32(0.3).data)
        XCTAssertEqual(c2.sky.saturation, 1, accuracy: 1e-6)
    }
}
