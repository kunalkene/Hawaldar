//
//  ContentView.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/1/24.
//

import SwiftUI
import LocalAuthentication
import CoreMotion

@MainActor
final class AppLock: ObservableObject {
    @Published var isLocked: Bool
    @Published var failed = false
    private var isAuthenticating = false

    static let defaultsKey = "lockEnabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    init() { isLocked = Self.isEnabled }

    func lockIfNeeded() {
        if Self.isEnabled { isLocked = true }
    }

    /// Face ID / Touch ID with device passcode fallback.
    func authenticate(reason: String = "Unlock Hawaldar") async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set: nothing to protect with, don't lock the user out.
            return true
        }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        failed = !ok
        return ok
    }

    func unlock() async {
        if await authenticate() { isLocked = false }
    }
}

/// Toggles code visibility each time the phone is turned face down and then back up.
@MainActor
final class CodeVisibility: ObservableObject {
    static let defaultsKey = "flipToHide"

    @Published var hidden = false

    private let motion = CMMotionManager()
    private var faceDownSince: Date?
    private var armed = false   // face-down held long enough

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let z = data?.gravity.z else { return }
            MainActor.assumeIsolated { self.handle(z: z) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        faceDownSince = nil
        armed = false
        hidden = false
    }

    /// gravity.z is about +1 when the screen faces the ground, about -1 when it faces the sky.
    private func handle(z: Double) {
        if z > 0.85 {
            if faceDownSince == nil { faceDownSince = Date() }
            if let since = faceDownSince, Date().timeIntervalSince(since) > 0.4 { armed = true }
        } else {
            faceDownSince = nil
            if armed && z < 0.5 {
                armed = false
                hidden.toggle()
            }
        }
    }
}

struct MainView: View {
    @StateObject private var lock = AppLock()
    @StateObject private var visibility = CodeVisibility()
    @AppStorage(CodeVisibility.defaultsKey) private var flipToHide = false
    @AppStorage(AccentStore.key) private var accentStored = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            tabs
                .environmentObject(lock)
                .environmentObject(visibility)

            if lock.isLocked || scenePhase != .active && AppLock.isEnabled {
                LockScreen(lock: lock)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.lockIfNeeded()
            case .active:
                if lock.isLocked { Task { await lock.unlock() } }
            default:
                break
            }
        }
        .onChange(of: flipToHide) { _, enabled in
            if enabled { visibility.start() } else { visibility.stop() }
        }
        .onAppear { if flipToHide { visibility.start() } }
        .task {
            if lock.isLocked { await lock.unlock() }
        }
    }

    /// The user's accent colour for screen content (the tab bar itself stays neutral).
    private var contentTint: Color { AccentStore.color(from: accentStored) ?? Color("AccentColor") }

    /// Codes and Settings tabs. Search lives on the Codes page: pull the list down to start it.
    private var tabs: some View {
        TabView {
            AuthenticatorView()
                .tint(contentTint)
                .tabItem { Label("Codes", systemImage: "key.fill") }
            SettingsView()
                .tint(contentTint)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.primary)
    }
}

private struct LockScreen: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Hawaldar is Locked")
                    .font(.title3.weight(.semibold))
                Button("Unlock") { Task { await lock.unlock() } }
                    .buttonStyle(.borderedProminent)
                    .opacity(lock.isLocked ? 1 : 0)
            }
        }
    }
}

#Preview {
    MainView()
}
