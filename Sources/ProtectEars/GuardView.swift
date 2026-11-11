import ServiceManagement
import SwiftUI
import VolumeGuardCore

struct GuardView: View {
    @ObservedObject var store: GuardStore

    private var accent: Color { store.snapshot.needsAttention ? .orange : .mint }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: store.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Protect Ears").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(store.heading).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("HEADPHONE CEILING")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.3)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(store.limit.percent)
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                HStack(spacing: 4) {
                    ForEach(0..<16, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index < store.limit.rawValue ? accent : Color.primary.opacity(0.08))
                            .frame(height: 22)
                    }
                }.accessibilityLabel("Maximum \(store.limit.rawValue) of 16 volume steps")
                Picker("Maximum volume", selection: Binding(get: { store.limit }, set: { store.setLimit($0) })) {
                    Text("4 steps · 25%").tag(VolumeLimit.fourSteps)
                    Text("5 steps · 31.25%").tag(VolumeLimit.fiveSteps)
                }.pickerStyle(.segmented)
                Text("AirPods Max are detected automatically. Once detected, this Mac remembers them even if you rename them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CONNECTED OUTPUTS").font(.system(size: 10, weight: .semibold))
                        .tracking(1.3).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: store.refresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Check devices and recover the audio connection if needed")
                        .accessibilityLabel("Refresh connected devices")
                }
                if store.snapshot.reports.isEmpty {
                    Text(store.snapshot.error == nil
                         ? "Connect your AirPods Max to this Mac to check the volume guard."
                         : "Audio detection is unavailable. The headphone ceiling cannot be verified.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(store.snapshot.reports) { report in deviceRow(report) }
                        }
                    }.frame(maxHeight: 170)
                }
                if let error = store.snapshot.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Start at login", isOn: Binding(
                    get: { store.launchStatus == .enabled || store.launchStatus == .requiresApproval },
                    set: { store.setStartAtLogin($0) }
                )).toggleStyle(.switch).controlSize(.small)
                if store.launchStatus == .requiresApproval {
                    Button("Allow Protect Ears in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        .font(.caption)
                }
                if let error = store.loginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                if store.snapshot.clampCount > 0 {
                    Text("Turned volume down \(store.snapshot.clampCount) \(store.snapshot.clampCount == 1 ? "time" : "times") this session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Not proven to protect hearing or prevent hearing damage. Loud spikes can get through before correction. Works only while running; volume steps are not a measured hearing-safety limit.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Sound settings…", action: store.openSoundSettings)
                    Spacer()
                    Button("Quit…") { confirmQuit() }
                }.font(.system(size: 11)).buttonStyle(.link)
            }
        }
        .padding(24)
        .frame(width: 410)
    }

    private func deviceRow(_ report: DeviceReport) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.isProtected ? "headphones" : "speaker.wave.2")
                .foregroundStyle(report.isProtected ? accent : .secondary)
                .frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.device.name).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(deviceStatus(report)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = report.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if report.device.isAirPodsMax {
                Image(systemName: "lock.fill").font(.system(size: 11))
                    .foregroundStyle(accent).help("AirPods Max are always selected")
            } else {
                Toggle("Cap \(report.device.name)", isOn: Binding(
                    get: { report.isProtected },
                    set: { store.setProtected($0, device: report.device) }
                )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    private func deviceStatus(_ report: DeviceReport) -> String {
        guard report.isProtected else { return "No ceiling selected" }
        if report.state == .failed { return "Volume guard could not be verified" }
        if report.muted { return "Muted" }
        if let volume = report.volume {
            return "\(Int((volume * 100).rounded()))% output · ceiling \(store.limit.percent)"
        }
        return "Checking output volume"
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Stop the volume guard?"
        alert.informativeText = "The AirPods volume ceiling is only enforced while Protect Ears is running."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertSecondButtonReturn { NSApplication.shared.terminate(nil) }
    }
}
