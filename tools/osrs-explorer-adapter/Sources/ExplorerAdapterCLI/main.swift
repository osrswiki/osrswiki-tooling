import Darwin
import ExplorerAdapterCore
import Foundation

@main
enum ExplorerAdapterCLI {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let paths = AdapterRuntimePaths.stable()
            let request = try ControlCLIRequestFactory.make(arguments: arguments)
            let response = try UnixSocketClient.send(request, to: paths.controlSocket.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(response))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if !response.ok { Foundation.exit(1) }
        } catch {
            FileHandle.standardError.write(Data("osrs-explorerctl failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

}
