import CryptoKit
import Foundation

/// Updates from GitHub Releases, the app's only update road.
///
/// Each release carries `appcast.json` (an `UpdateInfo` with
/// `sha256` and `signature`) and `Archivist.zip`. The feed is read from the latest
/// release, the zip downloaded over HTTPS (`ReleaseFeed.session`), and nothing is unpacked until
/// both checks pass: the zip's SHA-256 matches the feed, and the feed's signature over
/// "archivist-update-v1\n<version>\n<sha256>" verifies against `publicKey`, whose private half lives only in
/// Archivist's signing keychain on the release Mac (`tools/release.sh`). The unpacked folder then goes to the
/// installer, which checks the code signature again. The internet is not trusted, so the
/// signature is the whole of the trust.
public struct ReleaseFeed: Sendable {
    public static let repo = "House-of-Helios/archivist"
    /// The public half of the release signing key (`swift tools/release-sign.swift public`).
    public static let publicKeyBase64 = "+g72pyPdYReL4lryg75P3FLCSPXuy5cYI85XQ70Doso="

    /// Plain HTTPS: Archivist reaches nothing else on the network, so it carries no Tor.
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    /// A feed or a zip bigger than this is refused unread: GitHub could serve anything.
    public static let feedLimit = 256 << 10
    public static let zipLimit = 200 << 20

    public var feedURL: URL
    public var downloadBase: URL
    public var publicKey: Curve25519.Signing.PublicKey
    public var session: URLSession

    public init(feedURL: URL = URL(string: "https://github.com/\(repo)/releases/latest/download/appcast.json")!,
                downloadBase: URL = URL(string: "https://github.com/\(repo)/releases/download")!,
                publicKey: Curve25519.Signing.PublicKey = try! .init(rawRepresentation: Data(base64Encoded: publicKeyBase64)!),
                session: URLSession = ReleaseFeed.session) {
        self.feedURL = feedURL; self.downloadBase = downloadBase
        self.publicKey = publicKey; self.session = session
    }

    /// What the latest release says, as an `UpdateChecker.Status`.
    public func check(current: String) async -> UpdateChecker.Status {
        guard let (data, response) = try? await session.data(from: feedURL) else {
            return .offline(why: "Couldn't reach GitHub (\(Self.repo)).")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .offline(why: http.statusCode == 404
                ? "GitHub has no published release of \(Self.repo) yet (or the repository is private)."
                : "GitHub answered \(http.statusCode) for the update feed.")
        }
        guard data.count <= Self.feedLimit, let info = try? JSONDecoder().decode(UpdateInfo.self, from: data) else {
            return .unreadableFeed(path: feedURL.absoluteString)
        }
        return UpdateChecker.isNewer(info.version, than: current)
            ? .available(info) : .upToDate(current: current, published: info.version)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsigned, download(String), fingerprint, signature, unpack
        public var description: String {
            switch self {
            case .unsigned: return "The update carries no signature, so it wasn't installed."
            case .download(let why): return "Couldn't download the update: \(why)"
            case .fingerprint: return "The download didn't match its fingerprint, so it wasn't installed."
            case .signature: return "The update's signature didn't check out, so it wasn't installed."
            case .unpack: return "Couldn't unpack the update."
            }
        }
    }

    /// True when `signature` is the release key's signature over `version` and `sha256`.
    public func verifies(version: String, sha256: String, signature: String) -> Bool {
        guard let sig = Data(base64Encoded: signature),
              version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return false }
        return publicKey.isValidSignature(sig, for: Data("archivist-update-v1\n\(version)\n\(sha256.lowercased())".utf8))
    }

    /// Download `u`'s zip into `workDir` (emptied first: one update at a time, nothing
    /// piles up), check it, and unpack it there. Returns the folder holding the `.app`.
    public func fetch(_ u: UpdateInfo, into workDir: URL) async throws -> URL {
        guard let sha = u.sha256?.lowercased(), let sig = u.signature else { throw Failure.unsigned }
        // Checked before any byte is fetched, and again on the bytes.
        guard verifies(version: u.version, sha256: sha, signature: sig) else { throw Failure.signature }
        let name = "Archivist.zip"   // never a name the feed chooses

        let fm = FileManager.default
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = downloadBase.appendingPathComponent("v\(u.version)").appendingPathComponent(name)
        var data = Data()
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.download("HTTP \(http.statusCode)") }
            if response.expectedContentLength > Int64(Self.zipLimit) { throw Failure.download("the file is too big") }
            data.reserveCapacity(max(0, Int(response.expectedContentLength)))
            for try await b in bytes {
                data.append(b)
                if data.count > Self.zipLimit { throw Failure.download("the file is too big") }
            }
        } catch let f as Failure { throw f } catch { throw Failure.download(error.localizedDescription) }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha else { throw Failure.fingerprint }
        let zip = workDir.appendingPathComponent(name)
        try data.write(to: zip)

        let out = workDir.appendingPathComponent("unpacked", isDirectory: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run(); p.waitUntilExit()
        try? fm.removeItem(at: zip)
        guard p.terminationStatus == 0 else { throw Failure.unpack }
        return out
    }
}
