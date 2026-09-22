import Foundation
import CryptoKit
import BigInt

/// The Luanti engine's LOGIN handshake, reimplemented so this client can sign
/// in to a stock Luanti/VoxeLibre server the same way the official desktop
/// client does. Luanti authenticates players with SRP-6a (a password-
/// authenticated key exchange: the password itself is never sent, only a
/// verifier the server already holds), so any client that wants to join a
/// server has to speak it. This matches the engine's own implementation
/// (util/srp.cpp, the csrp library) bit-for-bit: SHA-256, the RFC 5054
/// 2048-bit group, g = 2, and csrp's padding conventions. Originally ported
/// via srp.gd. Used only for the player's own account on the server they
/// chose to connect to.
public final class SRP {
    static let nHex = "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"
    let N = BigUInt(SRP.nHex, radix: 16)!
    let g = BigUInt(2)
    var nBytes: Int { (N.bitWidth + 7) / 8 }   // 256

    let username: String            // as sent, used in M
    let usernameVerifier: String    // lowercased, used in x
    let password: Data
    var a = BigUInt(0)
    var A = BigUInt(0)
    public private(set) var sessionKey = Data()

    public init(username: String, password: String) {
        self.username = username
        self.usernameVerifier = username.lowercased()
        self.password = Data(password.utf8)
    }

    static func sha256(_ parts: [Data]) -> Data {
        var h = SHA256(); for p in parts { h.update(data: p) }; return Data(h.finalize())
    }
    private func pad(_ x: BigUInt, _ n: Int) -> Data {
        let d = x.serialize()
        return d.count < n ? Data(repeating: 0, count: n - d.count) + d : d
    }
    private func minimal(_ x: BigUInt) -> Data { x.serialize() }

    /// Start of login: returns A as minimal big-endian bytes.
    public func startAuthentication(privateA: Data? = nil) -> Data {
        let pa = privateA ?? SRP.randomBytes(32)
        a = BigUInt(pa)
        A = g.power(a, modulus: N)
        return minimal(A)
    }

    /// Registration (FIRST_SRP): returns (salt, verifier).
    public func generateVerifier(salt: Data? = nil) -> (salt: Data, verifier: Data) {
        let s = salt ?? SRP.randomBytes(16)
        let v = g.power(calcX(s), modulus: N)
        return (s, minimal(v))
    }

    /// Given the server's salt and B, returns the client proof M, or nil on the
    /// SRP-6a safety-check failure.
    public func processChallenge(salt: Data, B bBytes: Data) -> Data? {
        let B = BigUInt(bBytes)
        let u = hashNN(A, B)
        // SRP-6a safety check. csrp only tests B == 0; RFC 5054 wants
        // B mod N == 0 rejected too (a B of exactly N is the same trap).
        if (B % N).isZero || u.isZero { return nil }
        let x = calcX(salt)
        let k = hashNN(N, g)
        let gx = g.power(x, modulus: N)
        let kgx = (k * gx) % N
        let base = ((B % N) + N - kgx) % N          // B - k*g^x  (mod N)
        let S = base.power(a + u * x, modulus: N)    // ^(a + u*x)
        sessionKey = SRP.sha256([minimal(S)])
        return calcM(salt, B: B, K: sessionKey)
    }

    // x = H(salt | H(username_lower ":" password))
    private func calcX(_ salt: Data) -> BigUInt {
        let inner = SRP.sha256([Data(usernameVerifier.utf8), Data(":".utf8), password])
        return BigUInt(SRP.sha256([salt, inner]))
    }
    // H(PAD(n1) | PAD(n2))
    private func hashNN(_ n1: BigUInt, _ n2: BigUInt) -> BigUInt {
        BigUInt(SRP.sha256([pad(n1, nBytes), pad(n2, nBytes)]))
    }
    // M = H( (H(N) xor H(g)) | H(I) | salt | A | B | K ), A/B unpadded
    private func calcM(_ salt: Data, B: BigUInt, K: Data) -> Data {
        let hn = SRP.sha256([minimal(N)]), hg = SRP.sha256([minimal(g)])
        var hxor = Data(); for i in 0..<hn.count { hxor.append(hn[i] ^ hg[i]) }
        let hi = SRP.sha256([Data(username.utf8)])
        return SRP.sha256([hxor, hi, salt, minimal(A), minimal(B), K])
    }

    static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
}
