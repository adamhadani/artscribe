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
    /// Named explicitly rather than left to `UTType.audio`, which does not always
    /// have these registered on a given machine.
    ///
    /// **Ogg Vorbis is macOS-only**, and that is a measured fact rather than a
    /// guess: on iOS, `AVAssetReader` fails a `.ogg` with "Operation Stopped"
    /// (see `oggVorbisDoesNotDecodeOnThisPlatform`). Offering it in the iPad
    /// document picker would let someone choose a file the app then refuses to
    /// open — silent degradation of exactly the kind spec §8 forbids, and worse
    /// than the file simply being greyed out. `.opus` stays: Opus and Vorbis are
    /// different codecs and only Vorbis is missing.
    private static let extraExtensions: [String] = {
        var extensions = [
            "flac", "opus", "wav", "aiff", "aif", "aifc", "mp3", "m4a",
            "aac", "caf", "wma"
        ]
        #if os(macOS)
        extensions.append(contentsOf: ["ogg", "oga"])
        #endif
        return extensions
    }()

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
    ///
    /// macOS only, and the shape is why rather than the API: this *returns* the
    /// choice, which only a modal panel can do. iPad's document picker is a
    /// presentation with a callback, so opening a file there is a `.fileImporter`
    /// on a view rather than a function anyone can call — a different seam, not
    /// a different implementation of this one. `supported` above is the part both
    /// platforms share, and it stays available to both.
    #if os(macOS)
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
    #endif
}
