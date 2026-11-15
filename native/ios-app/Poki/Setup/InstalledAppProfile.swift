import Foundation

/// Information about the app's installed provisioning profile. Poki does not sign or update itself.
struct InstalledAppProfile {
    /// Retained for the existing setup assertion; there is no Apple Account sign-in in Poki.
    var signedIn: Bool { false }

    let expiry: Date? = Self.installedProfileExpiry() ?? Self.screenshotExpiry

    /// New Poki Setup builds leave this marker so a fresh install starts Poki automatically.
    static var installHandoff: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokiSetup/install-handoff.json")
    }

    /// The previous app version received a private signing identity here. Keep the path only to
    /// consume and delete that unused key during upgrade.
    static var handedIdentity: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokiSetup/signing-identity.json")
    }

    nonisolated private static var screenshotExpiry: Date? {
        #if targetEnvironment(simulator)
        guard UserDefaults.standard.object(forKey: "pokiSigningDays") != nil else { return nil }
        return Date().addingTimeInterval(UserDefaults.standard.double(forKey: "pokiSigningDays") * 86_400)
        #else
        nil
        #endif
    }

    /// Reads the expiration date from this app's embedded provisioning profile.
    nonisolated static func installedProfileExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let dict = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
        return dict?["ExpirationDate"] as? Date
    }
}

/// Existing test fixtures use the old type name; this alias has no signing or network operations.
typealias SelfSigner = InstalledAppProfile

struct ExpiryWarning {
    let expiry: Date

    init?(expiry: Date?, now: Date = .now) {
        guard let expiry, expiry.timeIntervalSince(now) <= 2 * 86_400 else { return nil }
        self.expiry = expiry
    }

    var message: String {
        let when = expiry.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale))
        return AppLocalization.text(LocalizedStringResource("Poki stops opening after \(when). Connect this iPhone to your Mac and ask your agent to renew it."))
    }
}
