//
//  AuthTablet.swift
//  Hawaldar
//
//  Created by Kunal Kene on 4/6/24.
//

import SwiftUI
import FASwiftUI
import UniformTypeIdentifiers
import SwiftData

/// Countdown ring. It only updates once a second (from the timeline above it) and lets a
/// linear animation fill in the motion, so rows aren't redrawn every frame and long-presses
/// (context menu) aren't interrupted. Drawn by hand because `Gauge` adds an end-cap dot.
struct TOTPRingView: View {
    let remaining: Int      // whole seconds left, 1...period
    let period: Int
    let cycle: Int          // changes when a new code starts
    var size: CGFloat = 30

    var body: some View {
        let tint: Color = remaining <= 5 ? .red : (remaining <= 10 ? .orange : .accentColor)
        let lineWidth = size * 0.14

        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: Double(remaining - 1) / Double(period))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        // Sweep smoothly toward next second's value...
        .animation(.linear(duration: 1), value: remaining)
        // ...but snap (don't sweep backwards) when a new code starts.
        .transaction(value: cycle) { $0.animation = nil }
        .accessibilityHidden(true)
    }
}

/// One countdown for the whole list (standard 30s codes).
struct SharedCountdownRing: View {
    var period = 30

    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), by: 1)) { context in
            let now = Int(context.date.timeIntervalSince1970.rounded())
            TOTPRingView(remaining: period - now % period, period: period, cycle: now / period, size: 28)
        }
        .accessibilityLabel("Codes refresh every \(period) seconds")
    }
}

struct AuthCodeView: View {

    var accountData: AccountData
    var isHidden = false
    var onReveal: () -> Void = {}

    @State private var copied = false

    var body: some View {
        // Re-evaluates once a second; the code itself only changes every `period` seconds.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), by: 1)) { context in
            // Snap to whole seconds so the countdown matches the wall clock.
            let now = Int(context.date.timeIntervalSince1970.rounded())
            let period = max(accountData.period, 1)
            let remaining = period - now % period
            let code = totpCode(for: accountData, at: Date(timeIntervalSince1970: TimeInterval(now)))

            Button {
                if isHidden { onReveal() } else { copy(code) }
            } label: {
            HStack(spacing: 12) {
                FAText(iconName: accountData.accountIcon, size: 22)
                    .frame(width: 40, height: 40)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(accountData.accountName)
                        .font(.headline)
                        .lineLimit(1)
                    if !accountData.identifier.isEmpty {
                        Text(verbatim: accountData.identifier)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                codeLabel(code, urgent: remaining <= 5)
                    .layoutPriority(1)

                // Standard 30s accounts share the ring at the top; only odd periods get their own.
                if code != nil, accountData.period != 30 {
                    TOTPRingView(remaining: remaining, period: period, cycle: now / period)
                }
            }
            .padding(.vertical, 4)
            }
            .foregroundStyle(.primary)
            .accessibilityHint("Copies the code")
        }
    }

    @ViewBuilder
    private func codeLabel(_ code: String?, urgent: Bool) -> some View {
        Group {
            if copied {
                Label("Copied", systemImage: "doc.on.doc.fill")
                    .foregroundStyle(.secondary)
            } else if isHidden, let code {
                let half = code.count / 2
                Text("\(String(repeating: "*", count: half)) \(String(repeating: "*", count: code.count - half))")
                    .foregroundStyle(urgent ? Color.red : Color.accentColor)
                    .accessibilityLabel("Code hidden")
            } else if let code {
                Text("\(code.prefix(code.count / 2)) \(code.suffix(code.count - code.count / 2))")
                    .foregroundStyle(urgent ? Color.red : Color.accentColor)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: code)
                    .animation(.easeInOut(duration: 0.3), value: urgent)
            } else {
                Label("Invalid key", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        }
        .font(.system(.title3, design: .monospaced, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    private func copy(_ code: String?) {
        guard let code else { return }
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: code]],
            options: [.expirationDate: Date().addingTimeInterval(60)]
        )
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.snappy) { copied = false }
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: AccountData.self, configurations: config)

    let sample = AccountData(accountName: "Apple", privateKey: "JBSWY3DPEHPK3PXP", identifier: "kunal.kene@icloud.com", accountIcon: "apple", keyType: "test", tokenCode: "111111", isPinned: 0)

    return List { AuthCodeView(accountData: sample) }
        .modelContainer(container)
}
