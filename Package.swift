// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Toolbox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Toolbox", targets: ["Toolbox"]),
        .executable(name: "pdftool", targets: ["pdftool"]),
    ],
    targets: [
        // Moteur partagé : toutes les opérations PDF / LaTeX, sans interface.
        .target(name: "PDFCore"),
        // Application de bureau SwiftUI.
        .executableTarget(name: "Toolbox", dependencies: ["PDFCore"]),
        // Commande terminal.
        .executableTarget(name: "pdftool", dependencies: ["PDFCore"]),
    ]
)
