import Foundation

// Ранний роутинг: в режиме --askpass SwiftUI не стартует.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--askpass") {
    Askpass.run(arguments: Array(arguments[(i + 1)...]))
}
Prefs.register()
MacXtermApp.main()
