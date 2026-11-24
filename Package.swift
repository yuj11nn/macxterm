// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacXterm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2")
    ],
    targets: [
        .executableTarget(
            name: "MacXterm",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/MacXterm"
        )
    ]
)
