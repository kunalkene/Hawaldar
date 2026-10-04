//
//  NewAccountView.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/13/24.
//

import SwiftUI
import CodeScanner
import FASwiftUI
import SwiftData
import SwiftOTP

func getValueFromUrl(urlString: String, paramName: String) -> String? {
    guard let components = URLComponents(string: urlString) else { return nil }
    return components.queryItems?.first(where: { $0.name == paramName })?.value
}

/// Normalises what people paste into the key field ("abcd efgh" -> "ABCDEFGH").
func cleanedSecret(_ raw: String) -> String {
    raw.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
}

func isValidSecret(_ raw: String) -> Bool {
    let secret = cleanedSecret(raw)
    return !secret.isEmpty && base32DecodeToData(secret) != nil
}

/// Cancel / confirm buttons for modal sheets. iOS 26+ uses the system icon style
/// (✕ and ✓); earlier versions fall back to text buttons.
struct ModalToolbar: ToolbarContent {
    var confirmTitle: String? = "Done"
    var confirmDisabled = false
    var onCancel: (() -> Void)?
    var onConfirm: () -> Void = {}

    var body: some ToolbarContent {
        if let onCancel {
            ToolbarItem(placement: .cancellationAction) {
                if #available(iOS 26, *) {
                    Button(role: .cancel, action: onCancel)
                } else {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        if let confirmTitle {
            ToolbarItem(placement: .confirmationAction) {
                if #available(iOS 26, *) {
                    Button(role: .confirm, action: onConfirm)
                        .disabled(confirmDisabled)
                } else {
                    Button(confirmTitle, action: onConfirm)
                        .disabled(confirmDisabled)
                }
            }
        }
    }
}

/// Brand icons that ship with the app (only the Brands font is bundled).
enum IconCatalog {
    struct Entry: Identifiable {
        let id: String
        let label: String
        let terms: [String]
    }

    static let all: [Entry] = FontAwesome.shared.store
        .filter { $0.value.styles.contains(.brands) }
        .map { Entry(id: $0.key, label: $0.value.label, terms: $0.value.searchTerms) }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static let popular: [Entry] = [
        "apple", "google", "microsoft", "github", "gitlab", "amazon", "aws", "facebook", "instagram",
        "x-twitter", "twitter", "linkedin", "discord", "slack", "dropbox", "paypal", "steam", "reddit",
        "twitch", "snapchat", "tiktok", "telegram", "whatsapp", "bitbucket", "cloudflare", "digitalocean",
        "stripe", "shopify", "spotify", "npm", "docker", "figma", "yahoo", "wordpress", "atlassian", "firefox"
    ].compactMap { byID[$0] }

    static func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.id.contains(q) || $0.label.lowercased().contains(q) || $0.terms.contains { $0.contains(q) }
        }
    }

    /// Best brand match for an account name like "GitHub (work)", or nil.
    static func guess(for name: String) -> String? {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        for word in words where byID[word] != nil { return word }
        let joined = words.joined()
        if byID[joined] != nil { return joined }
        return nil
    }
}

/// Row in the add/edit forms that opens the full icon picker.
struct IconPickerSection: View {
    @Binding var icon: String
    var onPick: () -> Void = {}
    @State private var showPicker = false

    var body: some View {
        Section {
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 14) {
                    FAText(iconName: icon, size: 30)
                        .frame(width: 52, height: 52)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Icon").foregroundStyle(.primary)
                        Text(icon).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showPicker) {
            IconPickerView(selection: $icon) { onPick() }
        }
    }
}

struct IconPickerView: View {
    @Binding var selection: String
    var onPick: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    private var results: [IconCatalog.Entry] { IconCatalog.search(query) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if query.isEmpty {
                    grid(title: "Popular", entries: IconCatalog.popular)
                    grid(title: "All Brands", entries: IconCatalog.all)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                } else {
                    grid(title: nil, entries: results)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search brands")
            .textInputAutocapitalization(.never)
            .navigationTitle("Choose Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ModalToolbar(onConfirm: { dismiss() })
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func grid(title: String?, entries: [IconCatalog.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(entries) { entry in
                    let selected = selection == entry.id
                    Button {
                        selection = entry.id
                        onPick()
                        UISelectionFeedbackGenerator().selectionChanged()
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            FAText(iconName: entry.id, size: 30)
                                .frame(height: 34)
                            Text(entry.label)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

struct NewAccountView: View {
    @State private var accountName = ""
    @State private var privateKey = ""
    @State private var identifier = ""
    @State private var accountIcon = "apple"
    @State private var iconChosenManually = false
    @State private var digits = 6
    @State private var period = 30
    @State private var algorithm = "SHA1"

    @State private var isShowingScanner: Bool
    @State private var scanError: String?
    /// Called with (new accounts, skipped duplicates) when a Google export code is scanned.
    private let onMigration: (([GoogleMigration.Imported], Int) -> Void)?
    private let initialCode: String?
    /// Closes the whole sheet; needed when this form is pushed inside another stack.
    private let closeSheet: (() -> Void)?
    @State private var handledInitialCode = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    init(isShowingScanner: Bool = false,
         initialCode: String? = nil,
         closeSheet: (() -> Void)? = nil,
         onMigration: (([GoogleMigration.Imported], Int) -> Void)? = nil) {
        self.onMigration = onMigration
        self.initialCode = initialCode
        self.closeSheet = closeSheet
        _isShowingScanner = State(initialValue: isShowingScanner)
    }

    private var keyIsValid: Bool { isValidSecret(privateKey) }
    private var canSave: Bool { !accountName.trimmingCharacters(in: .whitespaces).isEmpty && keyIsValid }

    var body: some View {
        Form {
            IconPickerSection(icon: $accountIcon) { iconChosenManually = true }

            Section("Account") {
                TextField("Name", text: $accountName)
                    .onChange(of: accountName) { _, newValue in
                        guard !iconChosenManually else { return }
                        if let guess = IconCatalog.guess(for: newValue) { accountIcon = guess }
                    }
                TextField("Email / Username (optional)", text: $identifier)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                HStack {
                    TextField("Secret Key", text: $privateKey)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button {
                        isShowingScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Scan QR code")
                }
            } header: {
                Text("Key")
            } footer: {
                if let scanError {
                    Text(scanError).foregroundStyle(.red)
                } else if !privateKey.isEmpty && !keyIsValid {
                    Text("This doesn't look like a valid key. Keys use letters A–Z and digits 2–7.")
                        .foregroundStyle(.red)
                } else {
                    Text("The setup key shown by the service, or scan its QR code.")
                }
            }
        }
        .navigationTitle("New Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ModalToolbar(confirmTitle: "Add", confirmDisabled: !canSave, onCancel: { finish() }, onConfirm: save)
        }
        .sheet(isPresented: $isShowingScanner) { scanner }
        .task {
            guard let initialCode, !handledInitialCode else { return }
            handledInitialCode = true
            handleScanned(initialCode)
        }
    }

    private func finish() {
        if let closeSheet { closeSheet() } else { dismiss() }
    }

    private var scanner: some View {
        NavigationStack {
            ZStack {
                CodeScannerView(codeTypes: [.qr]) { response in
                    isShowingScanner = false
                    switch response {
                    case .success(let result):
                        handleScanned(result.string)
                    case .failure(let error):
                        scanError = error.localizedDescription
                    }
                }
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.8), lineWidth: 3)
                    .frame(width: 240, height: 240)
            }
            .ignoresSafeArea()
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ModalToolbar(confirmTitle: nil, onCancel: { isShowingScanner = false })
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func handleScanned(_ string: String) {
        if string.hasPrefix("otpauth-migration://") {
            handleMigration(string)
            return
        }
        guard let components = URLComponents(string: string), components.scheme == "otpauth" else {
            scanError = "That QR code isn't a 2FA setup code."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        guard components.host?.lowercased() == "totp" else {
            scanError = "Only time-based (TOTP) codes are supported."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        guard let secret = getValueFromUrl(urlString: string, paramName: "secret")
                ?? getValueFromUrl(urlString: string, paramName: "data") else {
            scanError = "That QR code doesn't contain a key."
            return
        }

        // Label looks like "Issuer:account" or just "account".
        let label = String(components.path.dropFirst()).removingPercentEncoding ?? ""
        let parts = label.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let issuer = getValueFromUrl(urlString: string, paramName: "issuer") ?? (parts.count == 2 ? parts[0] : nil)

        scanError = nil
        let queryDigits = getValueFromUrl(urlString: string, paramName: "digits").flatMap(Int.init)
        let queryPeriod = getValueFromUrl(urlString: string, paramName: "period").flatMap(Int.init)
        digits = (6...8).contains(queryDigits ?? 6) ? (queryDigits ?? 6) : 6
        period = (queryPeriod ?? 30) > 0 ? (queryPeriod ?? 30) : 30
        let queryAlgorithm = (getValueFromUrl(urlString: string, paramName: "algorithm") ?? "SHA1").uppercased()
        algorithm = ["SHA1", "SHA256", "SHA512"].contains(queryAlgorithm) ? queryAlgorithm : "SHA1"
        privateKey = secret
        accountName = issuer ?? parts.first ?? label
        identifier = parts.count == 2 ? parts[1] : (issuer == nil ? "" : (parts.first ?? ""))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func handleMigration(_ string: String) {
        guard let imported = try? GoogleMigration.parse(string) else {
            scanError = "Couldn't read that export code. Try exporting from Google Authenticator again."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let existing = Set(((try? context.fetch(FetchDescriptor<AccountData>())) ?? []).map(\.secret))
        let fresh = imported.filter { !existing.contains($0.secret) }
        guard !fresh.isEmpty else {
            scanError = "All \(imported.count) accounts in that code are already added."
            return
        }
        scanError = nil
        // Close this sheet; the main screen shows the import confirmation.
        onMigration?(fresh, imported.count - fresh.count)
        dismiss()
    }

    private func save() {
        guard canSave else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let account = AccountData(
            accountName: accountName.trimmingCharacters(in: .whitespaces),
            privateKey: cleanedSecret(privateKey),
            identifier: identifier.trimmingCharacters(in: .whitespaces),
            accountIcon: accountIcon,
            keyType: "Time Based",
            tokenCode: "111111",
            isPinned: 0,
            digits: digits,
            period: period,
            algorithm: algorithm
        )
        account.moveSecretToKeychain()
        context.insert(account)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finish()
    }
}

/// Opens straight to the camera. A normal 2FA code opens the add form pre-filled;
/// a Google Authenticator export hands its accounts back for import.
struct ScanAccountView: View {
    var onMigration: ([GoogleMigration.Imported], Int) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var message: String?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                CodeScannerView(codeTypes: [.qr], scanMode: .oncePerCode, scanInterval: 1, isPaused: !path.isEmpty) { response in
                    if case .success(let result) = response { handle(result.string) }
                }
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.8), lineWidth: 3)
                    .frame(width: 240, height: 240)

                if let message {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 40)
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                }
            }
            .ignoresSafeArea()
            .animation(.easeInOut, value: message)
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ModalToolbar(confirmTitle: nil, onCancel: { dismiss() }) }
            .navigationDestination(for: String.self) { code in
                NewAccountView(initialCode: code, closeSheet: { dismiss() })
            }
        }
    }

    private func handle(_ code: String) {
        if code.hasPrefix("otpauth-migration://") {
            guard let result = try? GoogleMigration.importable(code, in: context) else {
                show("Couldn't read that export code. Try exporting again.")
                return
            }
            guard !result.fresh.isEmpty else {
                show("All \(result.total) accounts in that code are already added.")
                return
            }
            onMigration(result.fresh, result.skipped)
            dismiss()
        } else if code.hasPrefix("otpauth://") {
            message = nil
            path.append(code)
        } else {
            show("That QR code isn't a 2FA setup code.")
        }
    }

    private func show(_ text: String) {
        message = text
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

#Preview {
    NavigationStack { NewAccountView() }
}
