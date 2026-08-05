import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

/// A "File…" / "Photo Library…" source menu for importing an audio or video
/// clip. File… browses the file system (Files app, including iCloud Drive
/// and other cloud providers, on iOS; NSOpenPanel on macOS) — the picker
/// backing it differs per platform, matched to how the rest of this
/// AppKit/iOS-hosted app already opens files. Photo Library… uses SwiftUI's
/// PhotosPicker, which is the same API on both platforms, so that source is
/// identical on iOS and macOS. Photos only ever holds video, not standalone
/// audio, so that source is filtered to `.videos`. Either entry ends up
/// calling `onPick` with a local file URL; failures (an unreadable pick, a
/// failed iCloud Photos download) go to `onError` instead of disappearing
/// silently.
struct MediaSourceMenu<Label: View>: View {
    var onPick: (URL) -> Void
    var onError: (String) -> Void = { _ in }
    @ViewBuilder var label: () -> Label

    private let contentTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .wav, .mp3]

    #if os(iOS)
    @State private var showFileImporter = false
    #endif
    @State private var showPhotosPicker = false
    @State private var photosItem: PhotosPickerItem?
    @State private var lastPhotosCopy: URL?

    var body: some View {
        Menu {
            Button("File…") { pickFile() }
            Button("Photo Library…") { showPhotosPicker = true }
        } label: { label() }
        .menuIndicator(.hidden)
        #if os(iOS)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: contentTypes) { result in
            switch result {
            case .success(let url): onPick(url)
            case .failure(let error): onError(error.localizedDescription)
            }
        }
        #endif
        .photosPicker(isPresented: $showPhotosPicker, selection: $photosItem, matching: .videos)
        .onChange(of: photosItem) { _, item in
            guard let item else { return }
            photosItem = nil
            Task {
                do {
                    let media = try await item.loadTransferable(type: PickedMediaFile.self)
                    guard let media else { throw PickedMediaError.unsupported }
                    if let previous = lastPhotosCopy { try? FileManager.default.removeItem(at: previous) }
                    lastPhotosCopy = media.url
                    onPick(media.url)
                } catch {
                    onError("Couldn't load that Photos item: \(error.localizedDescription)")
                }
            }
        }
    }

    private func pickFile() {
        #if os(macOS)
        // Dispatched async: running a modal panel directly from a Menu's
        // Button action races the menu's own dismissal and can leave the
        // panel not showing (or stuck behind the app window).
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = contentTypes
            if panel.runModal() == .OK, let url = panel.url {
                onPick(url)
            }
        }
        #else
        showFileImporter = true
        #endif
    }
}

private enum PickedMediaError: Error {
    case unsupported
}

/// Copies a Photos-picked video into the app's temp directory so the engine
/// gets a plain, already-owned file URL — the same shape it gets from the
/// file pickers above — instead of a Photos-managed one.
private struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}
