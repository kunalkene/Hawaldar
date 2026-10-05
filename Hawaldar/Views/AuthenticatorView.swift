//
//  AuthenticatorView.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/6/24.
//

import SwiftUI
import SwiftData

private enum AuthSheet: Identifiable {
    case scan, manual
    var id: Self { self }
}

/// Search stays hidden until the toolbar's search button opens it. (iOS 17 keeps a normal
/// always-available search field, since the button needs iOS 18's `isPresented` search.)
private struct SearchField: ViewModifier {
    @Binding var text: String
    @Binding var presented: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            if presented {
                content.searchable(text: $text, isPresented: $presented, prompt: "Search Codes")
            } else {
                content
            }
        } else {
            content.searchable(text: $text, prompt: "Search Codes")
        }
    }
}

/// "3 accounts" under the large title (iOS 26 navigation subtitle).
private struct AccountCountSubtitle: ViewModifier {
    let count: Int

    func body(content: Content) -> some View {
        if #available(iOS 26, *), count > 0 {
            content.navigationSubtitle("\(count) account\(count == 1 ? "" : "s")")
        } else {
            content
        }
    }
}

struct AuthenticatorView: View {
    @State private var searchPresented = false

    @Environment(\.modelContext) private var context
    @Query(sort: \AccountData.isPinned, order: .reverse) private var accounts: [AccountData]

    @State private var sheet: AuthSheet?
    @State private var accountToEdit: AccountData?
    @State private var accountToDelete: AccountData?
    @State private var searchText = ""
    @State private var pinTick = 0
    @EnvironmentObject private var visibility: CodeVisibility
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
                } else if !searchText.isEmpty, filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
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
                    .contentMargins(.top, filtered.contains { $0.isPinned != 0 } ? 0 : 24, for: .scrollContent)
                    .listSectionSpacing(.compact)
                    .modifier(SearchField(text: $searchText, presented: $searchPresented))
                    .animation(.snappy(duration: 0.4), value: accounts.map(\.isPinned))
                    .sensoryFeedback(.impact(flexibility: .soft), trigger: pinTick)
                }
            }
            .navigationTitle("Codes")
            .modifier(AccountCountSubtitle(count: accounts.count))
            .sensoryFeedback(.impact(weight: .medium), trigger: visibility.hidden)
            .task {
                // One-time move of legacy plaintext secrets into the Keychain.
                for account in accounts { account.moveSecretToKeychain() }
            }
            .toolbar {
                if !accounts.isEmpty { ringToolbarItem }
                searchToolbarItem
                ToolbarItem(placement: .topBarTrailing) { addMenu }
            }
            .sheet(item: $sheet, onDismiss: {
                // Wait for the add sheet to finish closing before presenting the import prompt.
                if !pendingImport.isEmpty { showImportDialog = true }
            }) { sheet in
                switch sheet {
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
                // Neutral icons: keep the app's accent colour out of the menu.
                Button { togglePin(item) } label: {
                    Label(item.isPinned == 0 ? "Pin" : "Unpin",
                          systemImage: item.isPinned == 0 ? "pin" : "pin.slash")
                }
                .tint(.primary)
                Button { accountToEdit = item } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.primary)
                Button(role: .destructive) { accountToDelete = item } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
    }

    /// Plain, non-interactive ring: iOS 26 would otherwise wrap it in a glass button circle.
    @ToolbarContentBuilder
    private var ringToolbarItem: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: .topBarLeading) { SharedCountdownRing() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { SharedCountdownRing() }
        }
    }

    /// Opens the search field and keyboard. Needs iOS 18's `isPresented` search.
    @ToolbarContentBuilder
    private var searchToolbarItem: some ToolbarContent {
        if #available(iOS 18, *) {
            ToolbarItem(placement: .topBarTrailing) {
                Button { searchPresented = true } label: {
                    Image(systemName: "magnifyingglass")
                }
                .tint(.primary)
                .accessibilityLabel("Search")
            }
        }
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
        .tint(.primary)
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
        .environmentObject(CodeVisibility())
        .modelContainer(for: AccountData.self, inMemory: true)
}
