// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "HaishinKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/shogo4405/Logboard.git", "2.3.1"..<"2.4.0")
    ],
    targets: [
        .binaryTarget(
            name: "libsrt",
            path: "Vendor/SRT/libsrt.xcframework"
        ),
        .target(name: "SwiftPMSupport"),
        .target(name: "HaishinKit",
                dependencies: ["Logboard", "SwiftPMSupport", "libsrt"],
                path: "Sources",
                sources: [
                    "Codec",
                    "Extension",
                    "FLV",
                    "Media",
                    "MPEG",
                    "Net",
                    "RTMP",
                    "Util",
                    "SRT",
                ])
    ]
)
