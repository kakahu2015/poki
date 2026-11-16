import AuthenticationServices
import CryptoKit
import Foundation
import Network
import PiSwiftAI
import Security
import SwiftUI

private let chatGPTOpenIDURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
private let chatGPTResource = "https://api.openai.com/v1"
private let chatGPTScopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
private let chatGPTDirectScope = "chatgpt.tokens.use.direct"

/// A ChatGPT registration and its credentials share a Keychain account record. Signed-out records keep
/// only their issued client ID and verified identity, so the same registration can be reused without tokens.
struct ChatGPTStoredAccount: Codable, Identifiable, Sendable {
    var schemaVersion: Int = 1
    var credentials: OAuthCredentials?
    var idToken: String?
    var subject: String?
    var email: String?
    var clientId: String?
    var scopes: [String]?
    var hostId: String?

    var id: String { clientId ?? "unregistered" }
}

private struct ChatGPTAccountCollection: Codable {
    var schemaVersion = 1
    var activeClientId: String?
    var accounts: [ChatGPTStoredAccount]
}

enum ChatGPTAccount {
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    static var signedIn: Bool {
        guard let account = currentAccount() else { return false }
        return isSignedIn(account)
    }

    static func isSignedIn(_ account: ChatGPTStoredAccount) -> Bool {
        guard let credentials = account.credentials,
              credentials.clientId == account.clientId,
              let subject = account.subject, !subject.isEmpty,
              let idToken = account.idToken, !idToken.isEmpty else { return false }
        return account.scopes?.contains(chatGPTDirectScope) == true
            && credentials.scopes?.contains(chatGPTDirectScope) == true
    }

    static func save(_ account: ChatGPTStoredAccount) throws {
        var collection = loadCollection() ?? ChatGPTAccountCollection(accounts: [])
        if let index = collection.accounts.firstIndex(where: { $0.clientId == account.clientId }) {
            collection.accounts[index] = account
        } else {
            collection.accounts.append(account)
        }
        collection.activeClientId = account.clientId
        try save(collection)
    }

    static var registeredAccounts: [ChatGPTStoredAccount] { loadCollection()?.accounts ?? [] }

    static func currentAccount() -> ChatGPTStoredAccount? {
        guard let collection = loadCollection(), !collection.accounts.isEmpty else { return nil }
        return collection.accounts.first(where: { $0.clientId == collection.activeClientId }) ?? collection.accounts.first
    }

    static func select(clientId: String) throws {
        guard var collection = loadCollection(), collection.accounts.contains(where: { $0.clientId == clientId }) else { return }
        collection.activeClientId = clientId
        try save(collection)
    }

    private static func save(_ collection: ChatGPTAccountCollection) throws {
        let data = try JSONEncoder().encode(collection)
        try ModelKeys.save(String(decoding: data, as: UTF8.self), for: .chatgpt)
    }

    private static func loadCollection() -> ChatGPTAccountCollection? {
        guard let stored = ModelKeys.key(.chatgpt) else { return nil }
        guard let data = stored.data(using: .utf8) else { return nil }
        if let collection = try? JSONDecoder().decode(ChatGPTAccountCollection.self, from: data), collection.schemaVersion == 1 {
            return collection
        }
        if let account = try? JSONDecoder().decode(ChatGPTStoredAccount.self, from: data), account.schemaVersion == 1 {
            return ChatGPTAccountCollection(activeClientId: account.clientId, accounts: [account])
        }
        // Older app builds saved PiSwift's OAuthCredentials directly. Reuse its issued registration for
        // reauthorization, but require a new verified ID token before using that legacy credential again.
        guard let credentials = try? JSONDecoder().decode(OAuthCredentials.self, from: data),
              credentials.clientId?.isEmpty == false else { return nil }
        let account = ChatGPTStoredAccount(credentials: credentials, email: credentials.email,
                                           clientId: credentials.clientId, scopes: credentials.scopes,
                                           hostId: hostIdentifier)
        return ChatGPTAccountCollection(activeClientId: account.clientId, accounts: [account])
    }

    /// Stable UUID for this installation, represented in OpenAI's required `urn:uuid:` form.
    static var hostIdentifier: String {
        if let saved = savedHostIdentifier { return saved }
        return "urn:uuid:\(installationID)"
    }

    private static var installationID: String {
        if let existing = UserDefaults.standard.string(forKey: "chat.installationID") { return existing.lowercased() }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "chat.installationID")
        return id
    }

    private static var savedHostIdentifier: String? {
        guard let stored = ModelKeys.key(.chatgpt), let data = stored.data(using: .utf8) else { return nil }
        if let collection = try? JSONDecoder().decode(ChatGPTAccountCollection.self, from: data) {
            return collection.accounts.compactMap(\.hostId).first
        }
        if let account = try? JSONDecoder().decode(ChatGPTStoredAccount.self, from: data) { return account.hostId }
        return nil
    }

    static func accessToken() async -> String? { await ChatGPTCredentialManager.shared.accessToken() }
    static func signOut() async -> ChatGPTSignOutResult { await ChatGPTCredentialManager.shared.signOut() }
}

private struct ChatGPTAuthorization: Sendable {
    let code: String
    let clientId: String
}

private struct ChatGPTOAuthFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum ChatGPTSignOutResult: Sendable {
    case localClearFailed
    case signedOut(remoteRevoked: Bool)
}

@MainActor
final class ChatGPTBrowserLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var activeCancel: CancellationToken?

    func signIn(registerNewAccount: Bool = false) async throws -> ChatGPTStoredAccount {
        let signal = CancellationToken()
        activeCancel = signal
        let registration = registerNewAccount ? nil : ChatGPTAccount.currentAccount()
        let existingClientId = registration?.clientId.flatMap { $0.isEmpty ? nil : $0 }
        let hostIdentifier = registration?.hostId ?? ChatGPTAccount.hostIdentifier
        let verifier = randomValue()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomValue()
        let nonce = randomValue()
        let configuration = try await OpenAIIDToken.configuration()

        let callback = try await OAuthCallbackServer<ChatGPTAuthorization>.start(
            providerName: "ChatGPT", host: "127.0.0.1", port: 0,
            path: "/auth/callback", redirectHost: "127.0.0.1", state: state,
            mode: .standard, signal: signal, timeoutMs: 180_000
        ) { components in
            let query = components.queryItems ?? []
            guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw ChatGPTOAuthFailure("OpenAI did not return an authorization code.")
            }
            let returnedClientId = query.first(where: { $0.name == "client_id" })?.value
            if let existingClientId {
                if let returnedClientId, returnedClientId != existingClientId {
                    throw ChatGPTOAuthFailure("OpenAI returned a different ChatGPT registration. Sign-in was not saved.")
                }
                return ChatGPTAuthorization(code: code, clientId: existingClientId)
            }
            guard let issuedClientId = returnedClientId, !issuedClientId.isEmpty,
                  issuedClientId != "dynamic_agent_client" else {
                throw ChatGPTOAuthFailure("OpenAI did not finish registering this app.")
            }
            return ChatGPTAuthorization(code: code, clientId: issuedClientId)
        }
        defer {
            activeCancel = nil
            session?.cancel()
            session = nil
            Task { await callback.close() }
        }

        let redirectURI = await callback.redirectUri()
        var authorize = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "client_id", value: existingClientId ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: hostIdentifier),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "resource", value: chatGPTResource),
            URLQueryItem(name: "scope", value: chatGPTScopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        if existingClientId == nil {
            query.append(URLQueryItem(name: "agent_name_hint", value: "kaka"))
        } else if let idToken = registration?.idToken, !idToken.isEmpty {
            query.append(URLQueryItem(name: "id_token_hint", value: idToken))
        } else if let email = registration?.email, !email.isEmpty {
            query.append(URLQueryItem(name: "login_hint", value: email))
        }
        authorize.queryItems = query
        guard let authorizeURL = authorize.url else { throw ChatGPTOAuthFailure("Could not start ChatGPT sign-in.") }

        // OpenAI requires an HTTP loopback redirect. Keep a listener on 127.0.0.1 and use Apple's
        // system-managed authentication session; the browser request reaches this listener directly.
        try openInSystemBrowser(authorizeURL)
        guard let authorization = try await callback.wait() else {
            throw ChatGPTOAuthFailure("ChatGPT sign-in did not complete its loopback callback.")
        }
        activeCancel = nil
        session?.cancel()
        session = nil

        let tokens = try await ChatGPTCredentialManager.shared.exchangeCode(
            authorization, verifier: verifier, redirectURI: redirectURI,
            tokenEndpoint: configuration.tokenEndpoint
        )
        guard let idToken = tokens.idToken, let grantedScope = tokens.scope else {
            throw ChatGPTOAuthFailure("OpenAI did not return the ID token and granted scopes required for sign-in.")
        }
        guard let refreshToken = tokens.refreshToken else {
            throw ChatGPTOAuthFailure("OpenAI did not return a renewable sign-in token.")
        }
        let identity = try await OpenAIIDToken.verify(idToken, clientId: authorization.clientId, nonce: nonce, configuration: configuration)
        if let priorSubject = registration?.subject, priorSubject != identity.subject {
            throw ChatGPTOAuthFailure("This ChatGPT registration belongs to a different account. Its credentials were not replaced.")
        }
        let scopes = grantedScope.split(whereSeparator: \.isWhitespace).map(String.init)
        guard scopes.contains(chatGPTDirectScope) else {
            throw ChatGPTOAuthFailure("ChatGPT plan use was not authorized. Allow it in the OpenAI sign-in screen and try again.")
        }
        let credentials = OAuthCredentials(
            refresh: refreshToken, access: tokens.accessToken,
            expires: Date().timeIntervalSince1970 * 1000 + tokens.expiresIn * 1000 - 180_000,
            email: identity.email, clientId: authorization.clientId, scopes: scopes
        )
        return ChatGPTStoredAccount(
            credentials: credentials, idToken: idToken, subject: identity.subject,
            email: identity.email, clientId: authorization.clientId, scopes: scopes,
            hostId: hostIdentifier
        )
    }

    func cancel() {
        activeCancel?.cancel()
        activeCancel = nil
        session?.cancel()
        session = nil
    }

    private func openInSystemBrowser(_ url: URL) throws {
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("poki")) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.session = nil
                self?.activeCancel?.cancel()
                self?.activeCancel = nil
            }
        }
        session.presentationContextProvider = self
        self.session = session
        guard session.start() else {
            self.session = nil
            throw ChatGPTOAuthFailure("Could not open the secure ChatGPT sign-in session.")
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
                fatalError("ChatGPT sign-in requires an active window scene")
            }
            return scene.keyWindow ?? UIWindow(windowScene: scene)
        }
    }
}

/// The ChatGPT row's sheet: system-browser sign-in, one-time usage disclosure, and sign-out.
struct ChatGPTSignIn: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var working = false
    @State private var problem: String?
    @State private var login = ChatGPTBrowserLogin()
    @State private var showPlanWelcome = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { run { try await login.signIn() } } label: {
                        HStack(spacing: 10) {
                            Image("Provider-openai").renderingMode(.template).resizable().scaledToFit()
                                .frame(width: 22, height: 22).foregroundStyle(.white)
                            Text("Continue with ChatGPT").font(.body.weight(.semibold)).foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(working)
                    if !ChatGPTAccount.registeredAccounts.isEmpty {
                        Button("Add another account") { run { try await login.signIn(registerNewAccount: true) } }
                            .disabled(working)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Eligible requests in kaka use your ChatGPT plan or credits. Usage limits are managed by OpenAI and may be shared across apps.")
                        Link("Manage usage", destination: ChatGPTAccount.usageURL)
                    }
                }
                if !ChatGPTAccount.registeredAccounts.isEmpty {
                    Section("Saved ChatGPT Accounts") {
                        ForEach(ChatGPTAccount.registeredAccounts) { account in
                            Button { choose(account) } label: {
                                HStack {
                                    Text(verbatim: account.email ?? "ChatGPT account")
                                    Spacer()
                                    if ChatGPTAccount.currentAccount()?.clientId == account.clientId {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .disabled(working)
                        }
                    }
                }
                if let problem { Text(verbatim: problem).foregroundStyle(Color(.systemRed)) }
                if ChatGPTAccount.signedIn {
                    Section {
                        Link("Manage usage", destination: ChatGPTAccount.usageURL)
                        Button("Sign Out", role: .destructive) { signOut() }.disabled(working)
                    }
                }
            }
            .navigationTitle(Text(verbatim: "ChatGPT"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { login.cancel(); dismiss() } } }
            .alert("You're using your ChatGPT plan", isPresented: $showPlanWelcome) {
                Button("Manage usage") { acknowledgePlanWelcome(); openURL(ChatGPTAccount.usageURL); dismiss() }
                Button("Got it", role: .cancel) { acknowledgePlanWelcome(); dismiss() }
            } message: {
                Text("Eligible requests in kaka use your ChatGPT plan or credits. You can review usage and manage limits in ChatGPT Settings.")
            }
            .onDisappear { login.cancel() }
        }
    }

    private func run(_ signIn: @escaping () async throws -> ChatGPTStoredAccount) {
        problem = nil
        working = true
        Task {
            do {
                let account = try await signIn()
                try ChatGPTAccount.save(account)
                ModelKeys.selectedProvider = .chatgpt
                working = false
                if UserDefaults.standard.bool(forKey: "chat.chatGPTPlanWelcomeSeen") {
                    dismiss()
                } else {
                    showPlanWelcome = true
                }
            } catch {
                problem = error.localizedDescription
                working = false
            }
        }
    }

    private func signOut() {
        working = true
        Task {
            let result = await ChatGPTAccount.signOut()
            working = false
            switch result {
            case .localClearFailed:
                problem = AppLocalization.text(LocalizedStringResource("Could not clear the saved ChatGPT credentials from this iPhone."))
            case .signedOut(let remoteRevoked):
                if ModelKeys.selectedProvider == .chatgpt,
                   let other = ModelProvider.allCases.first(where: { $0 != .chatgpt && ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }) {
                    ModelKeys.selectedProvider = other
                }
                problem = remoteRevoked ? nil : AppLocalization.text(LocalizedStringResource("Signed out on this iPhone, but OpenAI did not confirm remote revocation. You can disconnect kaka in ChatGPT Settings → Usage."))
            }
        }
    }

    private func choose(_ account: ChatGPTStoredAccount) {
        guard let clientId = account.clientId else { return }
        do { try ChatGPTAccount.select(clientId: clientId) }
        catch {
            problem = error.localizedDescription
            return
        }
        if ChatGPTAccount.isSignedIn(account) {
            ModelKeys.selectedProvider = .chatgpt
            dismiss()
        } else {
            run { try await login.signIn() }
        }
    }

    private func acknowledgePlanWelcome() {
        UserDefaults.standard.set(true, forKey: "chat.chatGPTPlanWelcomeSeen")
    }
}

private struct OpenIDConfiguration: Decodable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let jwksURI: URL
    let revocationEndpoint: URL?
    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case revocationEndpoint = "revocation_endpoint"
    }
}

private struct OpenAIJWKSet: Decodable { let keys: [OpenAIJWK] }
private struct OpenAIJWK: Decodable { let kid: String; let kty: String; let alg: String?; let use: String?; let n: String; let e: String }

private struct OpenAIIDTokenClaims: Decodable {
    let iss: String
    let sub: String
    let email: String?
    let exp: Double
    let iat: Double
    let nonce: String
    let sid: String?
    let azp: String?
    let aud: Audience

    enum Audience: Decodable {
        case one(String)
        case many([String])
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .one(value) }
            else { self = .many(try container.decode([String].self)) }
        }
        func contains(_ value: String) -> Bool {
            switch self { case .one(let audience): audience == value; case .many(let audiences): audiences.contains(value) }
        }
        var isMultiple: Bool { if case .many(let audiences) = self { return audiences.count > 1 }; return false }
    }
}

private struct OpenAIIdentity {
    let subject: String
    let email: String?
}

private enum OpenAIIDToken {
    static func configuration() async throws -> OpenIDConfiguration {
        let configuration = try await getJSON(chatGPTOpenIDURL, as: OpenIDConfiguration.self)
        guard configuration.issuer == "https://auth.openai.com",
              isTrusted(configuration.authorizationEndpoint), isTrusted(configuration.tokenEndpoint),
              isTrusted(configuration.jwksURI),
              configuration.revocationEndpoint.map(isTrusted) ?? true else {
            throw ChatGPTOAuthFailure("Could not verify the OpenAI sign-in configuration.")
        }
        return configuration
    }

    private static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com"
    }

    static func verify(_ token: String, clientId: String, nonce: String, configuration: OpenIDConfiguration) async throws -> OpenAIIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = decodeBase64URL(String(parts[0])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String,
              let payloadData = decodeBase64URL(String(parts[1])),
              let signature = decodeBase64URL(String(parts[2])) else {
            throw ChatGPTOAuthFailure("OpenAI returned an invalid ID token.")
        }
        let jwks = try await getJSON(configuration.jwksURI, as: OpenAIJWKSet.self)
        guard let jwk = jwks.keys.first(where: { $0.kid == kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig") }),
              let modulus = decodeBase64URL(jwk.n), let exponent = decodeBase64URL(jwk.e) else {
            throw ChatGPTOAuthFailure("OpenAI’s signing key could not be verified.")
        }
        let publicKeyData = derSequence(derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, &keyError),
              SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256) else {
            throw ChatGPTOAuthFailure("OpenAI’s signing key could not be imported.")
        }
        let signedData = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signedData as CFData, signature as CFData, &keyError) else {
            throw ChatGPTOAuthFailure("OpenAI’s ID token signature is invalid.")
        }
        let claims = try JSONDecoder().decode(OpenAIIDTokenClaims.self, from: payloadData)
        let now = Date().timeIntervalSince1970
        guard claims.iss == configuration.issuer, claims.aud.contains(clientId),
              !claims.aud.isMultiple || claims.azp == clientId,
              claims.exp > now - 5, claims.iat <= now + 5, claims.iat < claims.exp,
              claims.nonce == nonce,
              claims.sid.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
              !claims.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTOAuthFailure("OpenAI’s ID token did not match this sign-in attempt.")
        }
        return OpenAIIdentity(subject: claims.sub, email: claims.email)
    }

    private static func getJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatGPTOAuthFailure("OpenAI sign-in verification could not reach its identity service.")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct ChatGPTTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let scope: String?
    let expiresIn: Double
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case scope
        case expiresIn = "expires_in"
    }
}

private enum ChatGPTCredentialManagerError: Error {
    case rejectedResponse
    case missingRegistration
}

private actor ChatGPTCredentialManager {
    static let shared = ChatGPTCredentialManager()

    func accessToken() async -> String? {
        guard var account = ChatGPTAccount.currentAccount(),
              var credentials = account.credentials,
              account.subject != nil, account.idToken != nil,
              account.scopes?.contains(chatGPTDirectScope) == true,
              credentials.clientId == account.clientId,
              credentials.scopes?.contains(chatGPTDirectScope) == true else { return nil }
        guard credentials.expires < Date().timeIntervalSince1970 * 1000 + 60_000 else { return credentials.access }
        do {
            let refreshed = try await refresh(credentials)
            let grantedScopes = refreshed.scope?.split(whereSeparator: \.isWhitespace).map(String.init) ?? credentials.scopes ?? []
            guard grantedScopes.contains(chatGPTDirectScope),
                  refreshed.expiresIn.isFinite, refreshed.expiresIn > 0 else { return nil }
            credentials = OAuthCredentials(
                refresh: refreshed.refreshToken ?? credentials.refresh, access: refreshed.accessToken,
                expires: Date().timeIntervalSince1970 * 1000 + refreshed.expiresIn * 1000 - 180_000,
                email: account.email, clientId: credentials.clientId, scopes: grantedScopes
            )
            account.credentials = credentials
            account.scopes = grantedScopes
            try ChatGPTAccount.save(account)
            return credentials.access
        } catch {
            return nil
        }
    }

    func signOut() async -> ChatGPTSignOutResult {
        guard var account = ChatGPTAccount.currentAccount() else { return .signedOut(remoteRevoked: true) }
        var revoked = true
        if let credentials = account.credentials, let clientId = account.clientId, !credentials.refresh.isEmpty {
            revoked = await revoke(refreshToken: credentials.refresh, clientId: clientId)
        }
        account.credentials = nil
        account.idToken = nil
        do { try ChatGPTAccount.save(account) } catch { return .localClearFailed }
        return .signedOut(remoteRevoked: revoked)
    }

    func exchangeCode(_ authorization: ChatGPTAuthorization, verifier: String, redirectURI: String, tokenEndpoint: URL) async throws -> ChatGPTTokenResponse {
        try await tokenRequest([
            "grant_type": "authorization_code", "client_id": authorization.clientId,
            "code": authorization.code, "code_verifier": verifier,
            "redirect_uri": redirectURI, "resource": chatGPTResource,
        ], endpoint: tokenEndpoint)
    }

    private func refresh(_ credentials: OAuthCredentials) async throws -> ChatGPTTokenResponse {
        guard let clientId = credentials.clientId, !clientId.isEmpty else { throw ChatGPTCredentialManagerError.missingRegistration }
        let configuration = try await OpenAIIDToken.configuration()
        return try await tokenRequest([
            "grant_type": "refresh_token", "client_id": clientId,
            "refresh_token": credentials.refresh, "resource": chatGPTResource,
        ], endpoint: configuration.tokenEndpoint)
    }

    private func tokenRequest(_ fields: [String: String], endpoint: URL) async throws -> ChatGPTTokenResponse {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let tokens = try? JSONDecoder().decode(ChatGPTTokenResponse.self, from: data),
              !tokens.accessToken.isEmpty,
              tokens.expiresIn.isFinite, tokens.expiresIn > 0 else {
            throw ChatGPTCredentialManagerError.rejectedResponse
        }
        return tokens
    }

    private func revoke(refreshToken: String, clientId: String) async -> Bool {
        for attempt in 0..<3 {
            do {
                let configuration = try await OpenAIIDToken.configuration()
                guard let endpoint = configuration.revocationEndpoint,
                      endpoint.scheme == "https", endpoint.host == "auth.openai.com" else { return false }
                var components = URLComponents()
                components.queryItems = [
                    URLQueryItem(name: "token", value: refreshToken),
                    URLQueryItem(name: "token_type_hint", value: "refresh_token"),
                    URLQueryItem(name: "client_id", value: clientId),
                ]
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ChatGPTCredentialManagerError.rejectedResponse }
                if http.statusCode == 200 { return true }
                if !(500..<600).contains(http.statusCode) { return false }
            } catch {
                if attempt == 2 { return false }
            }
            if attempt < 2 { try? await Task.sleep(for: .seconds(attempt + 1)) }
        }
        return false
    }
}

private func randomValue() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
    return base64URL(Data(bytes))
}

private func base64URL<D: DataProtocol>(_ data: D) -> String {
    Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
}

private func derLength(_ length: Int) -> [UInt8] {
    if length < 128 { return [UInt8(length)] }
    var value = length
    var bytes: [UInt8] = []
    while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
    return [0x80 | UInt8(bytes.count)] + bytes
}

private func derElement(tag: UInt8, content: [UInt8]) -> [UInt8] {
    [tag] + derLength(content.count) + content
}

private func derInteger(_ data: Data) -> [UInt8] {
    var bytes = Array(data)
    while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
    if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
    return derElement(tag: 0x02, content: bytes)
}

private func derSequence(_ content: [UInt8]) -> Data {
    Data(derElement(tag: 0x30, content: content))
}

#if DEBUG && targetEnvironment(simulator)
/// Simulator test runs only: `SIMCTL_CHILD_POKI_TEST_CREDENTIAL=<file>` names a JSON file on the Mac,
/// `{"provider": "chatgpt"|"anthropic"|…, "model"?: id, "secret": key or credential JSON}`. It is read
/// once at launch into the keychain and the provider is selected. Nothing is printed.
enum TestCredential {
    static func importIfGiven() {
        guard let path = ProcessInfo.processInfo.environment["POKI_TEST_CREDENTIAL"],
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = (json["provider"] as? String).flatMap(ModelProvider.init(rawValue:)),
              let secret = json["secret"] as? String else { return }
        try? ModelKeys.save(secret, for: provider)
        ModelKeys.selectedProvider = provider
        if let model = json["model"] as? String { ModelKeys.selectedModel = model }
    }
}
#endif
