// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TicketPilot",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TicketPilotCore"),
        .executableTarget(
            name: "TicketPilot",
            dependencies: ["TicketPilotCore"]
        ),
        .testTarget(
            name: "TicketPilotCoreTests",
            dependencies: ["TicketPilotCore"]
        ),
    ]
)
