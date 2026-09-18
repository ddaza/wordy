import Foundation
import Observation
import Security

protocol CloudKeyStoring: Sendable {
    func read() async throws -> String?
    func save(_ key: String) async throws
    func delete() async throws
}

actor OpenRouterKeychain: CloudKeyStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.wordy.app.openrouter",
         kSecAttrAccount as String: "api-key"]
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw KeychainError.unavailable }
        return key
    }

    func save(_ key: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw KeychainError.unavailable
            }
        } else if status != errSecSuccess {
            throw KeychainError.unavailable
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unavailable }
    }

    enum KeychainError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Wordy could not access the API key in Keychain. Unlock your Mac and try again."
        }
    }
}

@MainActor @Observable
final class CloudSettings {
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "wordy.advancedMode")
            if !isEnabled {
                isSelected = false
                onAuthorizationRevoked?()
            }
        }
    }

    private(set) var model: OpenRouterModel {
        didSet { defaults.set(model.rawValue, forKey: "wordy.openRouterModel") }
    }

    private(set) var isSelected: Bool {
        didSet {
            defaults.set(isSelected, forKey: "wordy.useCloudTranscription")
            onSelectionChanged?()
        }
    }

    var usesCloud: Bool {
        isEnabled && isSelected
    }

    var canSelectModel: Bool {
        isEnabled && hasKey && !isSaving
    }

    private(set) var keySaveSucceeded = false
    private(set) var hasKey = false
    private(set) var isSaving = false
    var message: String?
    @ObservationIgnored var onSelectionChanged: (() -> Void)?
    @ObservationIgnored var onAuthorizationRevoked: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: any CloudKeyStoring

    init(defaults: UserDefaults = .standard, keys: any CloudKeyStoring = OpenRouterKeychain()) {
        self.defaults = defaults
        self.keys = keys
        isEnabled = defaults.bool(forKey: "wordy.advancedMode")
        isSelected = defaults.bool(forKey: "wordy.useCloudTranscription")
        model = defaults.string(forKey: "wordy.openRouterModel").flatMap(OpenRouterModel.init) ?? .whisperLargeV3
    }

    @discardableResult
    func select(_ model: OpenRouterModel) -> Bool {
        guard canSelectModel else { return false }
        self.model = model
        isSelected = true
        return true
    }

    func useLocal() {
        isSelected = false
    }

    func refresh() async {
        do { hasKey = try await keys.read()?.isEmpty == false }
        catch { message = error.localizedDescription }
    }

    func saveKey(_ text: String) async {
        guard !isSaving else { return }
        keySaveSucceeded = false
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            message = "Paste a valid OpenRouter API key."; return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await keys.save(key)
            hasKey = true
            keySaveSucceeded = true
            message = "API key saved in Keychain."
        } catch { message = error.localizedDescription }
    }

    func removeKey() async {
        guard !isSaving else { return }
        keySaveSucceeded = false
        onAuthorizationRevoked?()
        isSaving = true
        defer { isSaving = false }
        do {
            try await keys.delete()
            hasKey = false
            isSelected = false
            keySaveSucceeded = false
            message = "API key removed."
        } catch { message = error.localizedDescription }
    }

    func authorizedKey() async throws -> String {
        guard isEnabled, !isSaving else { throw OpenRouterError.authorizationRequired }
        guard let key = try await keys.read(), !key.isEmpty else {
            hasKey = false
            throw OpenRouterError.missingKey
        }
        guard isEnabled, !isSaving else { throw OpenRouterError.authorizationRequired }
        return key
    }
}
