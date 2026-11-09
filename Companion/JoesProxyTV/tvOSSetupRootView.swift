import SwiftUI

/// Root view for the tvOS setup assistant.
struct TVOSSetupRootView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.10),
                    Color(red: 0.09, green: 0.11, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(alignment: .top, spacing: 40) {
                TVOSSetupProgressRail()
                    .frame(width: 380)
                    .focusSection()

                TVOSSetupStepContentView()
                    .frame(maxWidth: 1_020, maxHeight: .infinity, alignment: .top)
                    .focusSection()
            }
            .padding(.horizontal, 88)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task {
            await state.discoverAndConnect(source: "rootTask")
        }
        .accessibilityIdentifier("tvOSSetupRootView")
    }
}

private struct TVOSSetupProgressRail: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("JoesProxy TV")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(state.setupProgressText)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(TVOSSetupStep.allCases) { step in
                    Button {
                        state.go(to: step)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: iconName(for: state.status(for: step)))
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.railTitle)
                                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                Text(step.railSubtitle)
                                    .font(.system(size: 18, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .frame(minHeight: 70)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(state.currentStep == step ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(step.title), \(accessibilityStatus(for: state.status(for: step)))")
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text("Mac Host")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(state.manualMacHost.isEmpty ? "Not set" : state.manualMacHost)
                    .font(.system(size: 21, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Text(connectionStatusText)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }

    private var connectionStatusText: String {
        switch state.connectionState {
        case .disconnected: return "Not connected"
        case .discovering: return "Searching for Mac…"
        case .connecting(let proxy): return "Connecting to \(proxy.host)…"
        case .connected(let proxy): return "Connected · \(proxy.host)"
        case .rejected(let reason): return "Rejected: \(reason)"
        }
    }

    private func iconName(for status: TVOSSetupStepStatus) -> String {
        switch status {
        case .passed, .manualConfirmed:
            return "checkmark.circle.fill"
        case .blocked:
            return "exclamationmark.triangle.fill"
        case .inProgress:
            return "arrow.right.circle.fill"
        case .notStarted:
            return "circle"
        }
    }

    private func accessibilityStatus(for status: TVOSSetupStepStatus) -> String {
        switch status {
        case .passed:
            return "passed"
        case .manualConfirmed:
            return "confirmed"
        case .blocked(let issue):
            return "blocked: \(issue.title)"
        case .inProgress:
            return "in progress"
        case .notStarted:
            return "not started"
        }
    }
}

private struct TVOSSetupStepContentView: View {
    @EnvironmentObject private var state: TVOSSetupPresentationState

    var body: some View {
        TVOSSetupCard {
            switch state.currentStep {
            case .welcome:
                TVOSWelcomeStepView()
            case .findMac:
                TVOSFindMacStepView()
            case .checkReachability:
                TVOSReachabilityStepView()
            case .openHiddenProfilesMenu:
                TVOSHiddenProfilesStepView()
            case .installProfile:
                TVOSInstallProfileStepView()
            case .trustCertificate:
                TVOSTrustCertificateStepView()
            case .verifyTraffic:
                TVOSVerifyTrafficStepView()
            case .troubleshooting:
                TVOSTroubleshootingStepView()
            }
        }
    }
}

struct TVOSSetupCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct TVOSStepHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow.uppercased())
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TVOSInstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(verbatim: "\(number)")
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor.opacity(0.25)))
            Text(text)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TVOSPrimaryButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
    }
}
