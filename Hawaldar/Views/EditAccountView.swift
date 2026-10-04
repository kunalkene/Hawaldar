//
//  EditAccountView.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/27/24.
//

import SwiftUI
import FASwiftUI
import SwiftData

struct EditAccountView: View {
    @Environment(\.dismiss) private var dismiss

    let accountData: AccountData

    // Edit a copy so Cancel really cancels.
    @State private var name: String
    @State private var identifier: String
    @State private var icon: String

    init(accountData: AccountData) {
        self.accountData = accountData
        _name = State(initialValue: accountData.accountName)
        _identifier = State(initialValue: accountData.identifier)
        _icon = State(initialValue: accountData.accountIcon)
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            IconPickerSection(icon: $icon)

            Section("Account") {
                TextField("Name", text: $name)
                TextField("Email / Username (optional)", text: $identifier)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle("Edit Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ModalToolbar(confirmDisabled: !canSave, onCancel: { dismiss() }) {
                accountData.accountName = name.trimmingCharacters(in: .whitespaces)
                accountData.identifier = identifier.trimmingCharacters(in: .whitespaces)
                accountData.accountIcon = icon
                dismiss()
            }
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: AccountData.self, configurations: config)
    let sample = AccountData(accountName: "Apple", privateKey: "JBSWY3DPEHPK3PXP", identifier: "kunal.kene@icloud.com", accountIcon: "apple", keyType: "test", tokenCode: "111111", isPinned: 0)
    return NavigationStack { EditAccountView(accountData: sample) }
        .modelContainer(container)
}
