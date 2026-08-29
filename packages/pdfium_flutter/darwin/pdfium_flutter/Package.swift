// swift-tools-version:5.6
import PackageDescription

// HELLOHQ FORK — LOCAL binary target instead of upstream's remote one.
//
// Upstream declares
//   .binaryTarget(name: "PDFium", url: "github.com/espresso3389/pdfium-xcframework/...",
//                 checksum: "948d9257...")
// and SwiftPM's downloader queries the macOS keychain for credentials before
// every remote binary-target fetch. On headless CI images (Blacksmith macOS)
// that SecItemCopyMatching call hangs FOREVER — proven by sampled stacks,
// 2026-08-29. Integrity was never the issue; the download path itself is.
//
// The xcframework is provisioned into Frameworks/ (git-ignored) by
// tool/fetch-native.sh, which downloads the SAME artifact (identical SHA-256)
// from the attested HelloHQ/pdfium-xcframework mirror and verifies
// SHA-256 + SLSA provenance BEFORE extraction — the hellohq_db trust-gate
// pattern. A checkout without provisioning fails at resolve time with
// "does not contain a binary artifact", never silently.
let package = Package(
    name: "pdfium_flutter",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_13),
    ],
    products: [
        .library(
            name: "pdfium-flutter",
            targets: ["pdfium_flutter"]
        ),
    ],
    targets: [
        .target(
            name: "pdfium_flutter",
            dependencies: [
                .target(name: "PDFium"),
            ],
            path: "Sources/main"
        ),
        .binaryTarget(
            name: "PDFium",
            path: "Frameworks/PDFium.xcframework"
        ),
    ]
)
