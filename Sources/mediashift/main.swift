import AppKit
import ConversionKit
import Foundation

// A command line front end to the same engine as the app.

let usage = """
    usage: mediashift <file>... --to <format>
           mediashift <file>... --compress [light|balanced|strong]
           mediashift <file>... --strip-metadata
           mediashift <file> --list

    options:
      --out <folder>   write results here instead of next to the original
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var files: [URL] = []
var action: ConversionAction?
var options = ConversionOptions()
var listOnly = false

var arguments = Array(CommandLine.arguments.dropFirst())[...]
while let argument = arguments.popFirst() {
    switch argument {
    case "--to":
        guard let value = arguments.popFirst(), let format = FileFormat(fileExtension: value) else {
            fail("Unknown format.\n\n\(usage)")
        }
        action = .convert(format)
    case "--compress":
        action = .compress
        if let next = arguments.first, let level = CompressionLevel(rawValue: next) {
            options.compressionLevel = level
            arguments.removeFirst()
        }
    case "--strip-metadata":
        action = .stripMetadata
    case "--list":
        listOnly = true
    case "--out":
        guard let value = arguments.popFirst() else { fail(usage) }
        let folder = URL(fileURLWithPath: value, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fail("The folder \(value) could not be created.")
        }
        options.outputDirectory = folder
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        files.append(URL(fileURLWithPath: argument))
    }
}

if files.isEmpty { fail(usage) }

if listOnly {
    for action in ConversionCatalog.actions(for: files) { print(action.title) }
    exit(0)
}

guard let chosenAction = action else { fail(usage) }
let inputFiles = files
let chosenOptions = options

// WebKit and printing need a running application, though never a visible one.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in
    var failed = false
    for file in inputFiles {
        do {
            let result = try await Converter.run(chosenAction, on: file, options: chosenOptions)
            print(result.output.path)
            if let note = result.note { print("note: \(note)") }
        } catch {
            FileHandle.standardError.write(Data("\(file.lastPathComponent): \(error.localizedDescription)\n".utf8))
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}
application.run()
