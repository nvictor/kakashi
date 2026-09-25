// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "WorkflowCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WorkflowCore", targets: ["WorkflowCore"]),
               .executable(name: "workflow-validator", targets: ["workflow-validator"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [.target(name: "WorkflowCore", dependencies: [.product(name: "Yams", package: "Yams")]),
              .executableTarget(name: "workflow-validator", dependencies: ["WorkflowCore"]),
              .testTarget(name: "WorkflowCoreTests", dependencies: ["WorkflowCore"])])
