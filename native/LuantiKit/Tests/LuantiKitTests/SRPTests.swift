import XCTest
import BigInt
import CryptoKit
@testable import LuantiKit

/// A test double for the server half of the SRP-6a handshake, written against
/// csrp's conventions (util/srp.cpp) so the client's proof can be checked end
/// to end inside XCTest without a live Luanti. It only ever runs in this test.
final class SRPTests: XCTestCase {
    private let N = BigUInt(SRP.nHex, radix: 16)!
    private let g = BigUInt(2)

    private func H(_ parts: [Data]) -> Data { SRP.sha256(parts) }
    private func pad(_ x: BigUInt) -> Data {
        let d = x.serialize(), n = (N.bitWidth + 7) / 8
        return d.count < n ? Data(repeating: 0, count: n - d.count) + d : d
    }

    /// Server side: given the registered (salt, v) and the client's A, pick b,
    /// send B, and compute the M the client must present.
    private func serverChallenge(salt: Data, v: BigUInt, A: BigUInt, username: String, b: BigUInt)
        -> (B: BigUInt, expectedM: Data) {
        let k = BigUInt(H([pad(N), pad(g)]))
        let B = (k * v + g.power(b, modulus: N)) % N
        let u = BigUInt(H([pad(A), pad(B)]))
        let S = (A * v.power(u, modulus: N)).power(b, modulus: N)
        let K = H([S.serialize()])
        let hn = H([N.serialize()]), hg = H([g.serialize()])
        var hxor = Data(); for i in 0..<hn.count { hxor.append(hn[i] ^ hg[i]) }
        let M = H([hxor, H([Data(username.utf8)]), salt, A.serialize(), B.serialize(), K])
        return (B, M)
    }

    func testClientProofMatchesServerSideSRP6a() {
        let srp = SRP(username: "VrDev", password: "hunter2")
        let (salt, vBytes) = srp.generateVerifier(salt: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let A = BigUInt(srp.startAuthentication(privateA: Data(repeating: 0x5a, count: 32)))
        let (B, expected) = serverChallenge(salt: salt, v: BigUInt(vBytes), A: A,
                                            username: "VrDev", b: BigUInt(Data(repeating: 0x3c, count: 32)))
        let M = srp.processChallenge(salt: salt, B: B.serialize())
        XCTAssertEqual(M, expected)
        XCTAssertEqual(srp.sessionKey.count, 32)
    }

    /// The verifier hashes the LOWERCASED name (x = H(s | H(lower ":" pw)))
    /// while M hashes the name as typed: a mixed-case login must still verify
    /// against the account registered under the lowercase key.
    func testVerifierIsCaseInsensitiveInNameButProofIsNot() {
        let salt = Data([9, 9, 9, 9])
        let lower = SRP(username: "steve", password: "pw").generateVerifier(salt: salt).verifier
        let mixed = SRP(username: "StEvE", password: "pw").generateVerifier(salt: salt).verifier
        XCTAssertEqual(lower, mixed)
        XCTAssertNotEqual(SRP(username: "steve", password: "pw2").generateVerifier(salt: salt).verifier, lower)
    }

    func testWrongPasswordFailsTheProof() {
        let good = SRP(username: "steve", password: "right")
        let (salt, vBytes) = good.generateVerifier(salt: Data([7, 7]))
        let bad = SRP(username: "steve", password: "wrong")
        let A = BigUInt(bad.startAuthentication(privateA: Data(repeating: 1, count: 32)))
        let (B, expected) = serverChallenge(salt: salt, v: BigUInt(vBytes), A: A, username: "steve", b: BigUInt(12345))
        XCTAssertNotEqual(bad.processChallenge(salt: salt, B: B.serialize()), expected)
    }

    /// SRP-6a safety check: a zero B (or B == 0 mod N) must abort the login.
    func testZeroBIsRejected() {
        let srp = SRP(username: "steve", password: "pw")
        _ = srp.startAuthentication()
        XCTAssertNil(srp.processChallenge(salt: Data([1]), B: Data([0])))
        XCTAssertNil(srp.processChallenge(salt: Data([1]), B: N.serialize()))
    }
}
