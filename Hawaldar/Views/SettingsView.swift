//
//  SettingsView.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/6/24.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Accent colour persisted as "r,g,b" components; empty means the system default.
enum AccentStore {
    static let key = "accentColorHex"

    static func color(from stored: String) -> Color? {
        let parts = stored.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return Color(.sRGB, red: parts[0], green: parts[1], blue: parts[2])
    }

    static func string(from color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return "\(r),\(g),\(b)"
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage(AccentStore.key) private var accentStored = ""

    @AppStorage(AppLock.defaultsKey) private var lockEnabled = false
    @EnvironmentObject private var lock: AppLock

    @AppStorage(CodeVisibility.defaultsKey) private var flipToHide = false

    @State private var confirmWipe = false

    // Backup / restore
    private enum PasswordMode: Identifiable {
        case create
        case restore(Data)
        var id: String { if case .create = self { "create" } else { "restore" } }
    }
    @State private var passwordMode: PasswordMode?
    @State private var backupDocument: BackupDocument?
    @State private var exportType: UTType = .json
    @State private var exportName = "Hawaldar Backup"
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var info: InfoMessage?
    @State private var pendingInfo: InfoMessage?

    private struct InfoMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { AccentStore.color(from: accentStored) ?? .accentColor },
            set: { accentStored = AccentStore.string(from: $0) }
        )
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    ColorPicker("Accent Color", selection: accentBinding, supportsOpacity: false)

                    if !accentStored.isEmpty {
                        Button("Reset Accent Color") { accentStored = "" }
                    }
                }

                Section {
                    Toggle("Require Face ID", isOn: Binding(
                        get: { lockEnabled },
                        set: { newValue in
                            // Confirm identity before changing the lock either way.
                            Task {
                                if await lock.authenticate(reason: newValue ? "Turn on app lock" : "Turn off app lock") {
                                    lockEnabled = newValue
                                }
                            }
                        }
                    ))

                    Toggle("Flip to Hide Codes", isOn: $flipToHide)
                } header: {
                    Text("Security")
                } footer: {
                    Text("Hawaldar locks whenever you leave the app and hides codes in the app switcher. With Flip to Hide, turning your phone face down and back up hides all codes, and doing it again shows them. Tapping a hidden code also shows them.")
                }

                Section {
                    Button("Back Up Accounts…") {
                        Task {
                            // Backups contain every secret, so confirm it's really the owner.
                            if await lock.authenticate(reason: "Back up your accounts") { passwordMode = .create }
                        }
                    }
                    Button("Restore from Backup…") { showImporter = true }
                    HoldToConfirmRow(title: "Hold to Export Accounts") {
                        Task {
                            if await lock.authenticate(reason: "Export your accounts") { exportPlain() }
                        }
                    }
                } header: {
                    Text("Backup and Export")
                } footer: {
                    Text("Backups are encrypted with a password you choose, and Hawaldar can't recover a forgotten password. Export saves your accounts as unencrypted otpauth:// links so you can move them to another authenticator app. Anyone with that file can sign in as you, so delete it once you've imported it.")
                }

                Section("Data") {
                    Button("Delete All Accounts", role: .destructive) { confirmWipe = true }
                }

                Section {
                    LabeledContent("Version", value: version)
                    LabeledContent("Icons", value: "Font Awesome")
                } header: {
                    Text("About")
                } footer: {
                    Text("Designed and developed by Kunal Kene")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ModalToolbar(onConfirm: { dismiss() })
            }
            .sheet(item: $passwordMode, onDismiss: {
                // Present follow-ups only after the sheet has finished closing.
                if backupDocument != nil { showExporter = true }
                if let pendingInfo { info = pendingInfo; self.pendingInfo = nil }
            }) { mode in
                switch mode {
                case .create:
                    BackupPasswordSheet(title: "Back Up", confirmTitle: "Back Up", needsConfirmation: true) { password in
                        await createBackup(password: password)
                    }
                case .restore(let data):
                    BackupPasswordSheet(title: "Restore", confirmTitle: "Restore", needsConfirmation: false) { password in
                        await restoreBackup(data, password: password)
                    }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: backupDocument,
                contentType: exportType,
                defaultFilename: exportName
            ) { result in
                backupDocument = nil
                switch result {
                case .success where exportType == .plainText:
                    info = InfoMessage(title: "Accounts Exported", text: "The file isn't encrypted. Delete it once you've imported it into your other app.")
                case .success:
                    info = InfoMessage(title: "Backup Saved", text: "Keep the file and its password somewhere safe. You need both to restore.")
                case .failure(let error): info = InfoMessage(title: "Couldn't Save Backup", text: error.localizedDescription)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .alert(item: $info) { message in
                Alert(title: Text(message.title), message: Text(message.text), dismissButton: .default(Text("OK")))
            }
            .confirmationDialog(
                "Delete all accounts?",
                isPresented: $confirmWipe,
                titleVisibility: .visible
            ) {
                Button("Delete All Accounts", role: .destructive) {
                    let all = (try? context.fetch(FetchDescriptor<AccountData>())) ?? []
                    all.forEach { $0.deleteSecret() }
                    try? context.delete(model: AccountData.self)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            } message: {
                Text("You may lose access to services that rely on these codes. This can't be undone.")
            }
        }
    }
}

/// A row that must be pressed and held; a tinted fill sweeps across while holding.
private struct HoldToConfirmRow: View {
    let title: String
    var duration: Double = 1.0
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var completed = 0

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Color.accentColor)
            Spacer()
            Image(systemName: "hand.tap")
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            completed += 1
            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            action()
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: duration) : .easeOut(duration: 0.2)) {
                progress = pressing ? 1 : 0
            }
        }
        .listRowBackground(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color(.secondarySystemGroupedBackground)
                    Color.accentColor.opacity(0.18)
                        .frame(width: geo.size.width * progress)
                }
            }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: completed)
        // VoiceOver and Switch Control users can't hold, so expose a direct action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

extension SettingsView {
    /// Returns an error message, or nil on success (which also closes the sheet).
    fileprivate func createBackup(password: String) async -> String? {
        let accounts = ((try? context.fetch(FetchDescriptor<AccountData>())) ?? []).map {
            BackupCrypto.Account(name: $0.accountName, identifier: $0.identifier, secret: $0.secret,
                                 icon: $0.accountIcon, algorithm: $0.algorithm, digits: $0.digits,
                                 period: $0.period, pinned: $0.isPinned != 0)
        }
        guard !accounts.isEmpty else { return "There are no accounts to back up." }
        do {
            // Key derivation is deliberately slow; keep it off the main thread.
            let data = try await Task.detached { try BackupCrypto.encrypt(accounts, password: password) }.value
            backupDocument = BackupDocument(data: data)
            exportType = .json
            exportName = "Hawaldar Backup \(Date.now.formatted(.iso8601.year().month().day()))"
            passwordMode = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Plain-text list of standard otpauth:// links, one per line (readable by most authenticator apps).
    fileprivate func exportPlain() {
        let accounts = (try? context.fetch(FetchDescriptor<AccountData>())) ?? []
        guard !accounts.isEmpty else {
            info = InfoMessage(title: "Nothing to Export", text: "There are no accounts yet.")
            return
        }
        let lines = accounts.compactMap { account -> String? in
            var components = URLComponents()
            components.scheme = "otpauth"
            components.host = "totp"
            let label = account.identifier.isEmpty ? account.accountName : "\(account.accountName):\(account.identifier)"
            components.path = "/" + label
            components.queryItems = [
                URLQueryItem(name: "secret", value: account.secret),
                URLQueryItem(name: "issuer", value: account.accountName),
                URLQueryItem(name: "algorithm", value: account.algorithm),
                URLQueryItem(name: "digits", value: String(account.digits)),
                URLQueryItem(name: "period", value: String(account.period)),
            ]
            return components.string
        }
        backupDocument = BackupDocument(data: Data(lines.joined(separator: "\n").utf8))
        exportType = .plainText
        exportName = "Hawaldar Export \(Date.now.formatted(.iso8601.year().month().day()))"
        showExporter = true
    }

    fileprivate func restoreBackup(_ data: Data, password: String) async -> String? {
        do {
            let accounts = try await Task.detached { try BackupCrypto.decrypt(data, password: password) }.value
            let existing = Set(((try? context.fetch(FetchDescriptor<AccountData>())) ?? []).map(\.secret))
            var added = 0
            for item in accounts where !existing.contains(item.secret) {
                let account = AccountData(
                    accountName: item.name, privateKey: item.secret, identifier: item.identifier,
                    accountIcon: item.icon, keyType: "Time Based", tokenCode: "",
                    isPinned: item.pinned ? 1 : 0, digits: item.digits, period: item.period,
                    algorithm: item.algorithm
                )
                account.moveSecretToKeychain()
                context.insert(account)
                added += 1
            }
            passwordMode = nil
            let skipped = accounts.count - added
            pendingInfo = InfoMessage(
                title: "Backup Restored",
                text: "Added \(added) account\(added == 1 ? "" : "s")."
                    + (skipped > 0 ? " \(skipped) already on this device." : "")
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    fileprivate func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            info = InfoMessage(title: "Couldn't Open File", text: error.localizedDescription)
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), BackupCrypto.isBackup(data) else {
                info = InfoMessage(title: "Not a Backup", text: "That file isn't a Hawaldar backup.")
                return
            }
            passwordMode = .restore(data)
        }
    }
}

private struct BackupPasswordSheet: View {
    let title: String
    let confirmTitle: String
    let needsConfirmation: Bool
    let onSubmit: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var working = false

    private var valid: Bool {
        needsConfirmation ? (password.count >= 8 && password == confirmation) : !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                    if needsConfirmation {
                        SecureField("Confirm Password", text: $confirmation)
                            .textContentType(.newPassword)
                    }
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if needsConfirmation {
                        Text(password.count >= 8 || password.isEmpty
                             ? "Use a password you'll remember. It can't be recovered."
                             : "Use at least 8 characters.")
                    } else {
                        Text("Enter the password you chose when you made this backup.")
                    }
                }
                if working {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(working)
            .toolbar {
                ModalToolbar(confirmTitle: confirmTitle, confirmDisabled: !valid || working,
                             onCancel: { dismiss() }) {
                    working = true
                    error = nil
                    Task {
                        error = await onSubmit(password)
                        working = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppLock())
        .modelContainer(for: AccountData.self, inMemory: true)
}
