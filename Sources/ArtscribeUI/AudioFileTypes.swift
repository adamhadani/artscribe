import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// The file types the open panel offers.
///
/// `UTType.audio` covers everything CoreAudio declares, but a few container
/// extensions that AVFoundation can in fact decode are not always registered on
/// a given machine, so they are named explicitly rather than left to chance.
public enum AudioFileTypes {
    private static let extraExtensions = [
        "flac", "ogg", "oga", "opus", "wav", "aiff", "aif", "aifc", "mp3", "m4a",
        "aac", "caf", "wma"
    ]

    public static var supported: [UTType] {
        var types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        for ext in extraExtensions {
            guard let type = UTType(filenameExtension: ext) else { continue }
            guard !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }

    /// Runs the modal open panel and returns the chosen file, or `nil` if the
    /// user cancelled.
    @MainActor
    public static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = supported
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an audio file to transcribe."
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
