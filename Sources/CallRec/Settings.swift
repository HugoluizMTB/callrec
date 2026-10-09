// Preferências: chave da OpenAI (Keychain) e idioma da transcrição (UserDefaults)
import AppKit
import Security
import Speech

enum Settings {
    private static let service = "CallRec"
    private static let account = "openai-api-key"

    /// `OPENAI_API_KEY` no ambiente tem prioridade; senão, a chave salva no Keychain
    static var openAIKey: String? {
        if let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !k.isEmpty { return k }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func setOpenAIKey(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Idioma da transcrição: o escolhido no menu, senão o do sistema
    static var localeID: String? {
        get { UserDefaults.standard.string(forKey: "transcriptionLocale") }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptionLocale") }
    }

    static func transcriptionLocale() async -> Locale {
        let wanted = localeID.map { Locale(identifier: $0) } ?? Locale.current
        return await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? Locale(identifier: "en_US")
    }

    static let languages: [(String, String)] = [
        ("pt_BR", "Português (Brasil)"), ("en_US", "English (US)"), ("es_ES", "Español"),
    ]

    @MainActor
    static func askForKey() {
        let a = NSAlert()
        a.messageText = "Chave da API da OpenAI"
        a.informativeText = "Usada só para dar nome e resumir as ligações (o áudio nunca sai do Mac). Fica guardada no Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-..."
        a.accessoryView = field
        a.addButton(withTitle: "Salvar")
        a.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = field
        if a.runModal() == .alertFirstButtonReturn {
            setOpenAIKey(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
