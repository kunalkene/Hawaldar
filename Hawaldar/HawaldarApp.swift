//
//  HawaldarApp.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/1/24.
//

import SwiftUI
import SwiftData

@main
struct HawaldarApp: App {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage(AccentStore.key) private var accentStored = ""

    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(appearance.colorScheme)
                .tint(AccentStore.color(from: accentStored))
        }
        .modelContainer(for: AccountData.self)
    }
}
