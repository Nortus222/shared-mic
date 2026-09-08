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

            // TEMPORARY PHASE 1 SCAFFOLDING. There is no demand detection yet, so a
            // session has to be driven by hand for testing. Phase 3 removes both of
            // these and starts sessions automatically from AudioDemandObserver.
            HStack {
                Button("Start session") { model.startSession() }
                    .disabled(!model.canStart)
                Button("Stop session") { model.stopSession() }
                    .disabled(!model.canStop)
            }
            Text("Start/Stop are temporary: automatic activation arrives in Phase 3.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

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
        switch model.state {
        case .streaming: return .green
        case .idle: return .blue
        case .connecting, .starting, .stopping: return .yellow
        case .degraded: return .orange
        case .hardStop: return .red
        case .disconnected, .unpaired: return .gray
        }
    }

    private var byteCountText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(model.audioBytesReceived))
    }
}
