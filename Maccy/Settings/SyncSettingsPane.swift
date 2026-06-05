import AppKit
import CoreImage
import Defaults
import KeyboardShortcuts
import Settings
import SwiftUI

struct SyncSettingsPane: View {
  @Default(.syncEnabled) private var syncEnabled
  @Default(.syncDeviceName) private var deviceName
  @Default(.syncSendText) private var sendText
  @Default(.syncSendImages) private var sendImages
  @Default(.syncSendFiles) private var sendFiles
  @Default(.syncPairedDevice) private var pairedDevice

  @State private var sync = LanSyncService.shared

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(title: "", bottomDivider: true) {
        Toggle("Enable clipboard sync", isOn: $syncEnabled)
          .onChange(of: syncEnabled) { _, enabled in
            if enabled { sync.start() } else { sync.stop() }
          }
        statusRow
      }

      Settings.Section(label: { Text("Open phone clipboard") }) {
        KeyboardShortcuts.Recorder(for: .showRemoteClipboard)
      }

      Settings.Section(title: "This Mac", bottomDivider: true) {
        TextField("Name", text: $deviceName)
          .frame(width: 220)
      }

      Settings.Section(title: "Paired phone", bottomDivider: true) {
        pairingArea
      }

      Settings.Section(title: "Sync content") {
        Toggle("Text", isOn: $sendText)
        Toggle("Images", isOn: $sendImages)
        Toggle("Files", isOn: $sendFiles)
      }
    }
  }

  // MARK: - Status

  private var statusRow: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(sync.state == .connected ? Color.green : Color.secondary)
        .frame(width: 8, height: 8)
      Text(statusText).foregroundStyle(.secondary)
    }
  }

  private var statusText: String {
    switch sync.state {
    case .connected: return "Connected to \(sync.connectedPeerName)"
    case .pairing: return "Waiting for phone to scan…"
    case .listening: return pairedDevice != nil ? "Waiting for \(pairedDevice?.name ?? "phone")" : "Ready to pair"
    case .off: return "Off"
    }
  }

  // MARK: - Pairing

  @ViewBuilder
  private var pairingArea: some View {
    if let qr = sync.pairingQR, let image = Self.qrImage(qr) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Scan with the Maccy Android app:")
        Image(nsImage: image)
          .interpolation(.none)
          .resizable()
          .frame(width: 180, height: 180)
        Button("Cancel") { sync.cancelPairing() }
      }
    } else if let device = pairedDevice {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: "iphone")
          Text(device.name)
          Spacer()
        }
        Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Re-pair") { sync.enterPairingMode() }
          Button("Unpair", role: .destructive) { sync.unpair() }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text("No phone paired.").foregroundStyle(.secondary)
        Button("Pair New Device…") { sync.enterPairingMode() }
      }
    }
  }

  // MARK: - QR

  static func qrImage(_ string: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
  }
}
