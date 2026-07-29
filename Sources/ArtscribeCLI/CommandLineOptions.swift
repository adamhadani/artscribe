import ArtscribeKit
import Foundation

/// Parsed `artscribe-cli` invocation.
///
/// A plain struct with a plain parser: the CLI exists to *listen* to the audio
/// core, so everything here stays boring enough not to need testing of its own.
struct CommandLineOptions {
    var file: URL?
    var speed: Double = 1.0
    var loopStartSeconds: Double?
    var loopEndSeconds: Double?
    /// Substring of an output device name, or a device id.
    var device: String?
    var listDevices = false
    /// Seconds after which to switch to the next output device, for verifying
    /// that a device change preserves position, speed and loop.
    var switchAfterSeconds: Double?

    static let usage = """
        usage: artscribe-cli [options] <file> [speed] [loopStart loopEnd]
          speed              0.10 – 2.00 (default 1.0)
          loopStart/loopEnd  seconds
          --list-devices     print the output devices and exit
          --device <name>    play to the device whose name contains <name>
          --switch-after <s> switch to the next output device after <s> seconds
        """

    static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        var options = CommandLineOptions()
        var positional: [String] = []
        var index = 1
        while index < arguments.count {
            index += try options.consume(arguments, at: index, positional: &positional)
        }
        try options.apply(positional: positional)
        return options
    }

    /// Handles one argument. Returns how many arguments it consumed.
    private mutating func consume(
        _ arguments: [String], at index: Int, positional: inout [String]
    ) throws -> Int {
        let argument = arguments[index]
        func value() throws -> String {
            guard index + 1 < arguments.count else { throw CLIError.missingValue(argument) }
            return arguments[index + 1]
        }
        switch argument {
        case "--list-devices":
            listDevices = true
        case "--device":
            device = try value()
            return 2
        case "--switch-after":
            let text = try value()
            guard let seconds = Double(text) else { throw CLIError.notANumber(text) }
            switchAfterSeconds = seconds
            return 2
        case "-h", "--help":
            throw CLIError.help
        default:
            guard !argument.hasPrefix("--") else { throw CLIError.unknownOption(argument) }
            positional.append(argument)
        }
        return 1
    }

    private mutating func apply(positional: [String]) throws {
        if let first = positional.first { file = URL(fileURLWithPath: first) }
        if positional.count > 1 {
            guard let value = Double(positional[1]) else {
                throw CLIError.notANumber(positional[1])
            }
            speed = value
        }
        guard positional.count > 3 else { return }
        guard let start = Double(positional[2]), let end = Double(positional[3]) else {
            throw CLIError.notANumber("\(positional[2]) \(positional[3])")
        }
        guard end > start else { throw CLIError.emptyLoop }
        loopStartSeconds = start
        loopEndSeconds = end
    }
}

enum CLIError: Error, LocalizedError {
    case help
    case missingValue(String)
    case unknownOption(String)
    case notANumber(String)
    case emptyLoop
    case noSuchDevice(String)
    case noFile

    var errorDescription: String? {
        switch self {
        case .help: return CommandLineOptions.usage
        case .missingValue(let option): return "\(option) needs a value."
        case .unknownOption(let option): return "Unknown option \(option)."
        case .notANumber(let text): return "\(text) is not a number."
        case .emptyLoop: return "The loop end must be after the loop start."
        case .noSuchDevice(let name): return "No output device matches “\(name)”."
        case .noFile: return "No input file given.\n\n\(CommandLineOptions.usage)"
        }
    }
}
