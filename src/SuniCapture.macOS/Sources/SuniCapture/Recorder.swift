import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// H.264 MP4 of the primary display at 30 fps with the cursor; system audio only when asked.
/// The microphone is never configured. `completed` is the only signal that the MP4 is ready.
final class VideoRecorder: NSObject {
    var completed: ((URL) -> Void)?
    var failed: ((String) -> Void)?
    private(set) var isRecording = false
    private(set) var pixelSize = CGSize.zero
    private var stream: SCStream?
    private var partial: URL?
    private var destination: URL?
    private var finished = false
    private var timeout: Task<Void, Never>?
    private let sink = DiscardingOutput()

    func start(_ destination: URL, systemAudio: Bool) async {
        guard !isRecording else { failed?(L.t("engine.running")); return }
        guard destination.pathExtension.lowercased() == "mp4" else { failed?(L.t("engine.extension")); return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { failed?(L.t("engine.exists")); return }
        isRecording = true
        finished = false
        self.destination = destination
        let partial = destination.deletingPathExtension().appendingPathExtension(UUID().uuidString.prefix(8).lowercased() + ".partial.mp4")
        self.partial = partial
        do {
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            catch { throw AppError(L.t("desktop.failed")) }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw AppError(L.t("engine.noDisplay"))
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let info = SCShareableContent.info(for: filter)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded())
            configuration.height = Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded())
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.showsCursor = true
            configuration.queueDepth = 6
            configuration.capturesAudio = systemAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.captureMicrophone = false
            pixelSize = CGSize(width: configuration.width, height: configuration.height)

            let output = SCRecordingOutputConfiguration()
            output.outputURL = partial
            output.outputFileType = .mp4
            output.videoCodecType = .h264
            let recording = SCRecordingOutput(configuration: output, delegate: self)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DiscardingOutput.queue)
            if systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DiscardingOutput.queue) }
            try stream.addRecordingOutput(recording)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            stream = nil
            isRecording = false
            failed?(describe(error) + partialNote())
        }
    }

    /// Requests the end; the file is only reported once finalized and validated.
    func stop() {
        guard isRecording, let stream else { return }
        Task {
            do { try await stream.stopCapture() } catch { finish(error) }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            self?.finish(AppError(L.t("engine.timeout")))
        }
    }

    private func finish(_ error: Error?) {
        guard isRecording, !finished else { return }
        finished = true
        timeout?.cancel()
        stream = nil
        var failure = error.map(describe)
        if failure == nil, let partial, let destination {
            do {
                try Self.validateMP4(partial)
                // Never overwrite a destination created during recording.
                try FileManager.default.moveItem(at: partial, to: destination)
            } catch { failure = describe(error) }
        }
        isRecording = false
        if let failure { failed?(failure + partialNote()) } else if let destination { completed?(destination) }
    }

    private func partialNote() -> String {
        guard let partial, FileManager.default.fileExists(atPath: partial.path) else { return "" }
        return L.f("engine.partialFile", partial.path)
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? AppError { return error.message }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue { return L.t("desktop.failed") }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError { return L.t("engine.noWrite") }
        return L.t("engine.startFailed") + error.localizedDescription
    }

    /// A nonempty file is not enough: an interrupted recording can hold frames without the `moov` index.
    static func validateMP4(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var position: UInt64 = 0
        var fileType = false, movie = false, media = false
        func bigEndian(_ data: Data) -> UInt64 { data.reduce(0) { $0 << 8 | UInt64($1) } }
        while position < length {
            guard length - position >= 8 else { throw AppError(L.t("engine.invalidEnd")) }
            try handle.seek(toOffset: position)
            let header = try handle.read(upToCount: 8) ?? Data()
            guard header.count == 8 else { throw AppError(L.t("engine.invalidEnd")) }
            var size = bigEndian(header.prefix(4))
            var headerSize: UInt64 = 8
            if size == 1 {
                guard let large = try handle.read(upToCount: 8), large.count == 8 else { throw AppError(L.t("engine.truncated")) }
                size = bigEndian(large)
                headerSize = 16
            } else if size == 0 {
                size = length - position
            }
            guard size >= headerSize, size <= length - position else { throw AppError(L.t("engine.truncated")) }
            if size > headerSize {
                switch String(decoding: header.suffix(4), as: UTF8.self) {
                case "ftyp": fileType = true
                case "moov": movie = true
                case "mdat": media = true
                default: break
                }
            }
            position += size
        }
        guard fileType, movie, media else { throw AppError(L.t("engine.incomplete")) }
    }
}

extension VideoRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.finish(error) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.finish(error) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish(nil) }
    }
}

/// Frames are written by the recording output; this sink only keeps the stream from dropping them noisily.
nonisolated final class DiscardingOutput: NSObject, SCStreamOutput, Sendable {
    static let queue = DispatchQueue(label: "ch.suniworks.SuniCapture.frames")
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

// MARK: - Floating stop control

/// Always on top and excluded from the recording itself.
final class RecordingBar {
    private let panel: NSPanel

    init(model: AppModel) {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 285, height: 58),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L.t("record.barTitle")
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingBarView(model: model))
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: area.maxX - 305, y: area.maxY - 22 - 58))
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

private struct RecordingBarView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Color(red: 1, green: 0.27, blue: 0)).frame(width: 9, height: 9).padding(.trailing, 9)
            Text(model.stoppingRecording ? L.t("record.finishing") : model.barElapsed)
                .font(.system(size: model.stoppingRecording ? 14 : 17).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 70, alignment: .leading)
            Spacer(minLength: 8)
            Button { model.stopRecording() } label: {
                Text(L.t("record.stop")).foregroundStyle(.black).padding(.horizontal, 13).padding(.vertical, 6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(model.stoppingRecording)
        }
        .padding(.leading, 17).padding(.trailing, 14)
        .frame(width: 285, height: 58)
        .background(Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255), in: RoundedRectangle(cornerRadius: 10))
    }
}
