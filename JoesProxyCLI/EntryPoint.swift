import Foundation

@main
enum JoesProxyCLIEntryPoint {
    static func main() async {
        let code = await CLIApplication().run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(code.rawValue)
    }
}
