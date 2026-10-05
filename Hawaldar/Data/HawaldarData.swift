//
//  HawaldarData.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/13/24.
//

import Foundation
import SwiftData
import Security
import SwiftOTP
import CryptoKit
import CommonCrypto
import SwiftUI
import UniformTypeIdentifiers

/// Secrets live in the Keychain; the model only keeps a "kc:<uuid>" reference.
enum KeychainStore {
    private static let service = "com.hawaldar.secrets"
    static let prefix = "kc:"

    static func isReference(_ value: String) -> Bool { value.hasPrefix(prefix) }

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id]
    }

    @discardableResult
    static func save(_ secret: String, id: String) -> Bool {
        SecItemDelete(query(id) as CFDictionary)
        var attributes = query(id)
        attributes[kSecValueData as String] = Data(secret.utf8)
        // Survives encrypted backups/restores, unlike *ThisDeviceOnly.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read(id: String) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

@Model
class AccountData {
    var accountName: String
    /// Either the raw secret (legacy / Keychain unavailable) or a "kc:<uuid>" Keychain reference.
    @Attribute(.unique) var privateKey: String
    var identifier: String
    var accountIcon: String
    var keyType: String
    var tokenCode: String
    var isPinned: UInt8
    var digits: Int = 6
    var period: Int = 30
    var algorithm: String = "SHA1"

    init(accountName: String, privateKey: String, identifier: String, accountIcon: String, keyType: String, tokenCode: String, isPinned: UInt8, digits: Int = 6, period: Int = 30, algorithm: String = "SHA1") {
        self.accountName = accountName
        self.privateKey = privateKey
        self.identifier = identifier
        self.accountIcon = accountIcon
        self.keyType = keyType
        self.tokenCode = tokenCode
        self.isPinned = isPinned
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// The real base32 secret, resolved through the Keychain when needed.
    var secret: String {
        guard KeychainStore.isReference(privateKey) else { return privateKey }
        return KeychainStore.read(id: String(privateKey.dropFirst(KeychainStore.prefix.count))) ?? ""
    }

    /// Moves a plaintext secret into the Keychain. Leaves the model untouched if that fails.
    func moveSecretToKeychain() {
        guard !KeychainStore.isReference(privateKey) else { return }
        let id = UUID().uuidString
        if KeychainStore.save(privateKey, id: id) {
            privateKey = KeychainStore.prefix + id
        }
    }

    func deleteSecret() {
        guard KeychainStore.isReference(privateKey) else { return }
        KeychainStore.delete(id: String(privateKey.dropFirst(KeychainStore.prefix.count)))
    }
}

func totpCode(for account: AccountData, at date: Date) -> String? {
    guard let data = base32DecodeToData(account.secret) else { return nil }
    let algorithm: OTPAlgorithm
    switch account.algorithm.uppercased() {
    case "SHA256": algorithm = .sha256
    case "SHA512": algorithm = .sha512
    default: algorithm = .sha1
    }
    return TOTP(secret: data, digits: account.digits, timeInterval: account.period, algorithm: algorithm)?
        .generate(time: date)
}

/// Decodes Google Authenticator's `otpauth-migration://offline?data=...` export QR codes.
enum GoogleMigration {
    struct Imported: Identifiable {
        let id = UUID()
        var name: String
        var identifier: String
        var secret: String      // base32
        var algorithm: String
        var digits: Int
        var period = 30
    }

    enum ParseError: Error { case invalid }

    /// Parses an export code and drops accounts that are already stored (matched by secret).
    static func importable(_ urlString: String, in context: ModelContext) throws -> (fresh: [Imported], skipped: Int, total: Int) {
        let imported = try parse(urlString)
        let existing = Set(((try? context.fetch(FetchDescriptor<AccountData>())) ?? []).map(\.secret))
        let fresh = imported.filter { !existing.contains($0.secret) }
        return (fresh, imported.count - fresh.count, imported.count)
    }

    static func parse(_ urlString: String) throws -> [Imported] {
        guard let components = URLComponents(string: urlString),
              components.scheme == "otpauth-migration",
              var b64 = components.queryItems?.first(where: { $0.name == "data" })?.value
        else { throw ParseError.invalid }

        b64 = b64.replacingOccurrences(of: " ", with: "+")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { throw ParseError.invalid }

        var reader = ProtoReader(data: data)
        var accounts: [Imported] = []
        while let (field, wire) = reader.nextTag() {
            if field == 1, wire == 2, let bytes = reader.readBytes() {
                if let account = parseOtp(bytes) { accounts.append(account) }
            } else if !reader.skip(wire) {
                throw ParseError.invalid
            }
        }
        guard !accounts.isEmpty else { throw ParseError.invalid }
        return accounts
    }

    private static func parseOtp(_ data: Data) -> Imported? {
        var reader = ProtoReader(data: data)
        var secret = Data(), name = "", issuer = ""
        var algorithm = 1, digits = 1, type = 2
        while let (field, wire) = reader.nextTag() {
            switch (field, wire) {
            case (1, 2): secret = reader.readBytes() ?? Data()
            case (2, 2): name = String(data: reader.readBytes() ?? Data(), encoding: .utf8) ?? ""
            case (3, 2): issuer = String(data: reader.readBytes() ?? Data(), encoding: .utf8) ?? ""
            case (4, 0): algorithm = Int(reader.readVarint() ?? 1)
            case (5, 0): digits = Int(reader.readVarint() ?? 1)
            case (6, 0): type = Int(reader.readVarint() ?? 2)
            default: if !reader.skip(wire) { return nil }
            }
        }
        // Only TOTP (2) is supported; HOTP (1) needs a counter we don't track.
        guard !secret.isEmpty, type == 2 || type == 0 else { return nil }

        // Name is usually "Issuer:account" or just "account".
        let parts = name.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let account = parts.count == 2 ? parts[1] : name
        let title = !issuer.isEmpty ? issuer : (parts.count == 2 ? parts[0] : name)

        return Imported(
            name: title,
            identifier: title == account ? "" : account,
            secret: base32Encode(secret),
            algorithm: [2: "SHA256", 3: "SHA512"][algorithm] ?? "SHA1",
            digits: digits == 2 ? 8 : 6
        )
    }

    private static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var result = "", buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                result.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return result
    }
}

private struct ProtoReader {
    let data: Data
    var index = 0

    init(data: Data) { self.data = Data(data) }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while index < data.count, shift < 64 {
            let byte = data[index]; index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func nextTag() -> (field: Int, wire: Int)? {
        guard index < data.count, let tag = readVarint() else { return nil }
        return (Int(tag >> 3), Int(tag & 7))
    }

    mutating func readBytes() -> Data? {
        guard let length = readVarint(), index + Int(length) <= data.count else { return nil }
        defer { index += Int(length) }
        return data.subdata(in: index..<index + Int(length))
    }

    mutating func skip(_ wire: Int) -> Bool {
        switch wire {
        case 0: return readVarint() != nil
        case 1: index += 8
        case 2: return readBytes() != nil
        case 5: index += 4
        default: return false
        }
        return index <= data.count
    }
}

/// Password-encrypted backup file: PBKDF2-SHA256 -> AES-256-GCM, wrapped in a small JSON envelope.
enum BackupCrypto {
    struct Account: Codable {
        var name: String
        var identifier: String
        var secret: String
        var icon: String
        var algorithm: String
        var digits: Int
        var period: Int
        var pinned: Bool
    }

    struct Envelope: Codable {
        var app = "Hawaldar"
        var version = 1
        var kdf = "PBKDF2-HMAC-SHA256"
        var iterations: Int
        var salt: Data
        var sealed: Data      // AES.GCM combined: nonce + ciphertext + tag
    }

    enum BackupError: LocalizedError {
        case wrongPassword, notABackup, unsupported

        var errorDescription: String? {
            switch self {
            case .wrongPassword: "That password didn't work. Check it and try again."
            case .notABackup: "That file isn't a Hawaldar backup."
            case .unsupported: "That backup was made by a newer version of Hawaldar."
            }
        }
    }

    static let iterations = 600_000

    static func isBackup(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.app == "Hawaldar"
    }

    static func encrypt(_ accounts: [Account], password: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = deriveKey(password: password, salt: salt, iterations: iterations)
        let plain = try JSONEncoder().encode(accounts)
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw BackupError.notABackup }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(iterations: iterations, salt: salt, sealed: combined))
    }

    static func decrypt(_ data: Data, password: String) throws -> [Account] {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.app == "Hawaldar" else {
            throw BackupError.notABackup
        }
        guard envelope.version == 1, (1...10_000_000).contains(envelope.iterations) else { throw BackupError.unsupported }
        let key = deriveKey(password: password, salt: envelope.salt, iterations: envelope.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let plain = try? AES.GCM.open(box, using: key) else { throw BackupError.wrongPassword }
        guard let accounts = try? JSONDecoder().decode([Account].self, from: plain) else { throw BackupError.notABackup }
        return accounts
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let pw = Array(password.precomposedStringWithCompatibilityMapping.utf8).map { Int8(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltBytes in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                &derived, derived.count
            )
        }
        return SymmetricKey(data: derived)
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
