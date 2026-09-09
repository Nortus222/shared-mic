import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(model.statusText)
                    .font(.headline)
            }

            if let warning = model.fingerprintWarning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let host = model.pairedHost {
                Text("Windows host: \(host)")
                    .font(.caption)
                Text("Microphone: \(model.deviceLabel.isEmpty ? "unknown" : model.deviceLabel)\(model.micPresent ? "" : " (unavailable)")")
                    .font(.caption)
                Text("Audio received: \(byteCountText)")
                    .font(.caption)
                demandSection
                systemInputSection
            } else {
                pairingForm
            }

            if let notice = model.lastNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if model.pairedHost != nil {
                sessionControls
                Divider()
            }

            HStack {
                if model.pairedHost != nil {
                    Button("Unpair…") { model.unpair() }
                }
                Spacer()
                Button("Quit SharedMic") { model.quit() }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var demandSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.demandProcesses.isEmpty {
                Text("Demand: none — microphone is off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Demand: \(model.demandCount) app\(model.demandCount == 1 ? "" : "s") holding BlackHole")
                    .font(.caption)
                ForEach(model.demandProcesses, id: \.pid) { process in
                    Text("• \(process.bundleID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Text("Sessions: \(model.sessionCount) • Last activation: \(activationText) • Debounce fired: \(model.debounceFireCount)× (\(model.stopDebounceMs) ms)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var systemInputSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("System input: \(model.systemInputName ?? "unknown")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.systemInputIsBlackHole {
                Text("BlackHole is the system input: every app that opens input looks like demand. Prefer the built-in microphone in System Settings.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.isDisabled {
                    Button("Enable microphone") { model.enable() }
                } else {
                    Button("Disable microphone") { model.disable() }
                }
                Spacer()
                if model.holdRemaining != nil {
                    Button("Cancel hold") { model.cancelHold() }
                } else {
                    Button("Hold on 30 min") { model.beginHold() }
                        .disabled(model.isDisabled)
                }
            }
            if model.isDisabled {
                Text("Disabled: no audio is captured or sent, whatever apps request.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.holdRemaining != nil {
                Text("Force-on hold: sessions stay up for apps Core Audio cannot see. Expires automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Sessions start automatically when an app opens BlackHole.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pair with the Windows agent")
                .font(.subheadline)
            TextField("Host or IP address", text: $model.hostField)
            TextField("Port", text: $model.portField)
            // SecureField, not TextField: this is a 32-byte bearer secret, and
            // nothing about typing it once justifies leaving it legible on screen.
            SecureField("Pairing string", text: $model.pairingField)
                .font(.system(.body, design: .monospaced))
            Button(model.isPairing ? "Pairing…" : "Pair") { model.pair() }
                .disabled(model.isPairing || model.hostField.isEmpty || model.pairingField.isEmpty)
            Text("The Windows tray shows a 58-character pairing string. Hyphens, spaces and lowercase are all fine.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        if model.holdRemaining != nil { return .purple }
        switch model.state {
        case .streaming, .stopPending: return .green
        case .idle: return .blue
        case .connecting, .starting, .stopping: return .yellow
        case .degraded: return .orange
        case .hardStop: return .red
        case .disabled: return .gray
        case .disconnected, .unpaired: return .gray
        }
    }

    private var activationText: String {
        guard let ms = model.lastActivationLatencyMs else { return "—" }
        return String(format: "%.0f ms", ms)
    }

    private var byteCountText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(model.audioBytesReceived))
    }
}
