//
//  AuthenticatorView.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/6/24.
//

import SwiftUI
import SwiftData

private enum AuthSheet: Identifiable {
    case scan, manual, settings
    var id: Self { self }
}

/// iOS 26: search, Settings and Add share the bottom bar. Earlier systems keep search under
/// the title and put Settings and Add in the top bar.
private struct BottomBarToolbar<Settings: View, Add: View>: ViewModifier {
    let settings: Settings
    let add: Add

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { settings }
                ToolbarItem(placement: .bottomBar) { add }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) { settings }
                ToolbarItem(placement: .topBarTrailing) { add }
            }
        }
    }
}

struct AuthenticatorView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AccountData.isPinned, order: .reverse) private var accounts: [AccountData]

    @State private var sheet: AuthSheet?
    @State private var accountToEdit: AccountData?
    @State private var accountToDelete: AccountData?
    @State private var searchText = ""
    @State private var pinTick = 0
    @AppStorage(CodeVisibility.defaultsKey) private var flipToHide = false
    @StateObject private var visibility = CodeVisibility()
    @State private var pendingImport: [GoogleMigration.Imported] = []
    @State private var skippedDuplicates = 0
    @State private var showImportDialog = false

    private var filtered: [AccountData] {
        guard !searchText.isEmpty else { return accounts }
        return accounts.filter {
            $0.accountName.localizedCaseInsensitiveContains(searchText)
                || $0.identifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Accounts", systemImage: "key.viewfinder")
                    } description: {
                        Text("Add a 2FA account by scanning a QR code or entering the key manually.")
                    } actions: {
                        Button("Scan QR Code") { sheet = .scan }
                            .buttonStyle(.borderedProminent)
                        Button("Enter Manually") { sheet = .manual }
                    }
                } else {
                    List {
                        let pinned = filtered.filter { $0.isPinned != 0 }
                        let others = filtered.filter { $0.isPinned == 0 }
                        if !pinned.isEmpty {
                            Section("Pinned") { ForEach(pinned) { row($0) } }
                        }
                        // Same Section identity whether or not anything is pinned,
                        // so rows slide between sections instead of being rebuilt.
                        Section {
                            ForEach(others) { row($0) }
                        } header: {
                            if !pinned.isEmpty { Text("Accounts") }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .contentMargins(.top, 12, for: .scrollContent)
                    .searchable(text: $searchText, prompt: "Search Codes")
                    .animation(.snappy(duration: 0.4), value: accounts.map(\.isPinned))
                    .sensoryFeedback(.impact(flexibility: .soft), trigger: pinTick)
                }
            }
            .navigationTitle("Hawaldar")
            .onChange(of: flipToHide) { _, enabled in
                if enabled { visibility.start() } else { visibility.stop() }
            }
            .onAppear { if flipToHide { visibility.start() } }
            .sensoryFeedback(.impact(weight: .medium), trigger: visibility.hidden)
            .task {
                // One-time move of legacy plaintext secrets into the Keychain.
                for account in accounts { account.moveSecretToKeychain() }
            }
            .toolbar {
                if !accounts.isEmpty { ringToolbarItem }
            }
            .modifier(BottomBarToolbar(settings: settingsButton, add: addMenu))
            .sheet(item: $sheet, onDismiss: {
                // Wait for the add sheet to finish closing before presenting the import prompt.
                if !pendingImport.isEmpty { showImportDialog = true }
            }) { sheet in
                switch sheet {
                case .settings:
                    SettingsView()
                case .scan:
                    ScanAccountView { accounts, skipped in
                        pendingImport = accounts
                        skippedDuplicates = skipped
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                case .manual:
                    NavigationStack {
                        NewAccountView()
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $accountToEdit) { account in
                NavigationStack {
                    EditAccountView(accountData: account)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Import \(pendingImport.count) account\(pendingImport.count == 1 ? "" : "s")?",
                isPresented: $showImportDialog,
                titleVisibility: .visible
            ) {
                Button("Import \(pendingImport.count) Account\(pendingImport.count == 1 ? "" : "s")") {
                    importPending()
                }
                Button("Cancel", role: .cancel) { pendingImport = [] }
            } message: {
                Text(pendingImport.map(\.name).joined(separator: ", ")
                     + (skippedDuplicates > 0 ? "\n\(skippedDuplicates) already added and skipped." : ""))
            }
            .confirmationDialog(
                "Delete \(accountToDelete?.accountName ?? "account")?",
                isPresented: Binding(get: { accountToDelete != nil },
                                     set: { if !$0 { accountToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let account = accountToDelete {
                        account.deleteSecret()
                        context.delete(account)
                    }
                    accountToDelete = nil
                }
            } message: {
                Text("Make sure you can still sign in without this code. This can't be undone.")
            }
        }
    }

    private func row(_ item: AccountData) -> some View {
        AuthCodeView(accountData: item, isHidden: visibility.hidden) {
            withAnimation(.snappy) { visibility.hidden = false }
        }
        .listRowSeparator(.hidden)
            .contextMenu {
                Button { togglePin(item) } label: {
                    Label(item.isPinned == 0 ? "Pin" : "Unpin",
                          systemImage: item.isPinned == 0 ? "pin" : "pin.slash")
                }
                Button { accountToEdit = item } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) { accountToDelete = item } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    /// Plain, non-interactive ring: iOS 26 would otherwise wrap it in a glass button circle.
    @ToolbarContentBuilder
    private var ringToolbarItem: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: .topBarTrailing) { SharedCountdownRing() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { SharedCountdownRing() }
        }
    }

    private var settingsButton: some View {
        Button { sheet = .settings } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
    }

    private var addMenu: some View {
        Menu {
            Button { sheet = .scan } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
            Button { sheet = .manual } label: {
                Label("Enter Manually", systemImage: "keyboard")
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("Add account")
    }

    private func importPending() {
        for item in pendingImport {
            let account = AccountData(
                accountName: item.name,
                privateKey: item.secret,
                identifier: item.identifier,
                accountIcon: IconCatalog.guess(for: item.name) ?? "keybase",
                keyType: "Time Based",
                tokenCode: "",
                isPinned: 0,
                digits: item.digits,
                period: item.period,
                algorithm: item.algorithm
            )
            account.moveSecretToKeychain()
            context.insert(account)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        pendingImport = []
    }

    private func togglePin(_ account: AccountData) {
        pinTick += 1
        withAnimation(.snappy(duration: 0.4)) { account.isPinned = account.isPinned == 0 ? 1 : 0 }
    }
}

#Preview {
    AuthenticatorView()
        .modelContainer(for: AccountData.self, inMemory: true)
}
