// swift-tools-version: 6.0
// Plugin Airine pro Mac: aplikace v liště, příkaz `airine` (hooky Claude Code
// a Cursoru, místní MCP server přes stdio) a společné jádro s místní kopií.
// Návrh: docs/analyzy/2026-10-27-znalosti-katalog.md §8, §11 krok 2.
import PackageDescription

let package = Package(
    name: "AirinePlugin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "airine", targets: ["airine"]),
        .executable(name: "AirineLista", targets: ["AirineLista"]),
    ],
    targets: [
        .target(name: "AirineCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "airine", dependencies: ["AirineCore"]),
        .executableTarget(name: "AirineLista", dependencies: ["AirineCore"]),
        .testTarget(name: "AirineCoreTests", dependencies: ["AirineCore"]),
    ]
)
