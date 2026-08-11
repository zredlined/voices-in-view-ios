import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var refreshDate = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InputStatusCard(audio: model.audioCapture)
                routeDetails
                performanceDetails
                receiverGuide
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.audioCapture.refreshRoute()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                refreshDate = Date()
            }
        }
    }

    private var routeDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio route")
                .font(.headline)
            DiagnosticRow(label: "Port", value: model.audioCapture.routeSnapshot.inputName)
            DiagnosticRow(label: "Type", value: model.audioCapture.routeSnapshot.inputKind.rawValue)
            DiagnosticRow(
                label: "Available inputs",
                value: model.audioCapture.availableInputNames.isEmpty
                    ? "None reported"
                    : model.audioCapture.availableInputNames.joined(separator: ", ")
            )
            DiagnosticRow(
                label: "Preferred input",
                value: model.audioCapture.preferredInputName ?? "Automatic"
            )
            DiagnosticRow(
                label: "Channels",
                value: model.audioCapture.routeSnapshot.channelCount > 0
                    ? "\(model.audioCapture.routeSnapshot.channelCount)"
                    : "Not active"
            )
            DiagnosticRow(
                label: "Channel names",
                value: model.audioCapture.routeSnapshot.channelNames.isEmpty
                    ? "Not reported"
                    : model.audioCapture.routeSnapshot.channelNames.joined(separator: ", ")
            )
            DiagnosticRow(
                label: "Sample rate",
                value: model.audioCapture.routeSnapshot.sampleRate > 0
                    ? "\(Int(model.audioCapture.routeSnapshot.sampleRate)) Hz"
                    : "Not active"
            )
            DiagnosticRow(
                label: "Input latency",
                value: "\(Int(model.audioCapture.routeSnapshot.inputLatency * 1_000)) ms"
            )
            DiagnosticRow(
                label: "I/O buffer",
                value: "\(Int(model.audioCapture.routeSnapshot.ioBufferDuration * 1_000)) ms"
            )
            DiagnosticRow(label: "Last event", value: model.audioCapture.lastRouteEvent)
        }
        .appCard()
    }

    private var performanceDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live performance")
                .font(.headline)
            DiagnosticRow(label: "Speech model", value: model.modelReadiness.title)
            DiagnosticRow(label: "Dropped frames", value: "\(model.audioCapture.droppedFrameCount)")
            DiagnosticRow(
                label: "First caption",
                value: model.firstCaptionLatency.map { String(format: "%.2f s", $0) } ?? "Not measured"
            )
            DiagnosticRow(label: "Thermal state", value: ProcessDiagnostics.thermalState)
            DiagnosticRow(label: "App memory", value: ProcessDiagnostics.formattedResidentMemory)
            Text(refreshDate, style: .time)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityLabel("Diagnostics refreshed at \(refreshDate.formatted(date: .omitted, time: .standard))")
        }
        .appCard()
    }

    private var receiverGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("DJI receiver check", systemImage: "checklist")
                .font(.headline)
            Text("1. Use the small phone USB-C adapter in the receiver expansion port.")
            Text("2. Power on the receiver and both transmitters.")
            Text("3. Mic Mini: double-press the link button; cyan means Stereo.")
            Text("4. Mic 2: select S on the receiver touchscreen.")
            Text("5. Look for USB type and 2 channels above.")
            Text("Levels are audio strength, not DJI radio strength.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppTheme.warning)
        }
        .font(.subheadline)
        .foregroundStyle(AppTheme.primaryText)
        .appCard()
    }
}

private struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
