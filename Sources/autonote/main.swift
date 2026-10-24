import AutoNoteCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["--version"] {
    print(AutoNoteVersion.current)
    exit(0)
}

FileHandle.standardError.write(Data("usage: autonote --version\n".utf8))
exit(1)
