// swift-tools-version:5.9
// This package is only for checking the app's data core on any computer (it compiles the
// Core folder without the iPhone screens). The iPhone app itself is built from project.yml in Xcode.
import PackageDescription

let package = Package(
    name: "ShootDeskCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(name: "ShootDeskCore", path: "ShootDesk/Core"),
        .executableTarget(name: "CoreCheck", dependencies: ["ShootDeskCore"], path: "Tools/CoreCheck"),
    ]
)
