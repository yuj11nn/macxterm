import Foundation

// Ранний роутинг: в режимах --askpass и --mcp SwiftUI не стартует.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--askpass") {
    Askpass.run(arguments: Array(arguments[(i + 1)...]))
}
if arguments.contains("--mcp") {
    MCPBridge.run()
}
Prefs.register()
AgentController.registerDefaults()
MacXtermApp.main()
