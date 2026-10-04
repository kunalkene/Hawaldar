//
//  SettingsView.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/6/24.
//

import SwiftUI
import SwiftData

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

#Preview {
    SettingsView()
        .environmentObject(AppLock())
        .modelContainer(for: AccountData.self, inMemory: true)
}
