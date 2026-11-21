import XCTest
@testable import PlayerIdentity

/// v2.26 engine install policy: release metadata (T-E-R*, T-E-M4–M6), URL allowlist and redirects (T-E-N*,
/// T-E-RD1), archive allowlist (T-E-X*, E19.2), state machine (T-E-ST1), eligibility (T-E-UI1), identity verification
/// (T-E-IB2/IB3, T-E-K3/K4), privacy (T-E-LG1/LG2), tool output (T-E-ER1), commands (T-E-U1, T-E-PR2) and the backup
/// inventory (T-E-RT1–RT3).
final class EngineInstallPolicyTests: XCTestCase {
    private let goodDigest = "sha256:" + String(repeating: "ab", count: 32)

    private func parse(_ assets: [[String: Any]], architecture: EngineArchitecture = .arm64, tag: String = "continuous",
                       html: String = EngineReleaseSource.releasePageURL.absoluteString,
                       commitish: Any? = EngineReleaseFixture.commit, prerelease: Any? = true,
                       draft: Any? = false) -> Result<EngineRelease, EngineInstallFailure> {
        EngineReleaseParser.parse(EngineReleaseFixture.json(assets: assets, tag: tag, html: html, commitish: commitish,
                                                            prerelease: prerelease, draft: draft),
                                  architecture: architecture)
    }

    // MARK: Release metadata (T-E-R1 – T-E-R5, T-E-M4 – T-E-M6)

    func testParsesTheOfficialReleaseAndSelectsTheExactArm64Asset() throws {
        let result = parse([EngineReleaseFixture.asset(name: "xash3d-fwgs-apple-amd64.tar.xz", digest: goodDigest),
                            EngineReleaseFixture.asset(name: "xash3d-fwgs-apple-arm64.tar.xz.sha256", digest: goodDigest),
                            EngineReleaseFixture.asset(size: Int64(5_284_228), digest: goodDigest)])
        let release = try result.get()
        XCTAssertEqual(release.tag, "continuous")
        XCTAssertTrue(release.prerelease)
        XCTAssertEqual(release.commitSHA, EngineReleaseFixture.commit)
        XCTAssertEqual(release.commitURL.absoluteString,
                       "https://github.com/FWGS/xash3d-fwgs/commit/" + EngineReleaseFixture.commit)
        XCTAssertEqual(release.asset.name, "xash3d-fwgs-apple-arm64.tar.xz")
        XCTAssertEqual(release.asset.size, 5_284_228)
        XCTAssertEqual(release.asset.digest, goodDigest)
        XCTAssertEqual(release.asset.downloadURL.absoluteString,
                       "https://github.com/FWGS/xash3d-fwgs/releases/download/continuous/xash3d-fwgs-apple-arm64.tar.xz")
    }

    func testCommitMustBeExactly40LowercaseHex() {
        let asset = [EngineReleaseFixture.asset(digest: goodDigest)]
        for commitish: Any? in [nil, "master", EngineReleaseFixture.commit.uppercased(),
                                String(EngineReleaseFixture.commit.dropLast()), EngineReleaseFixture.commit + "0",
                                "g" + String(EngineReleaseFixture.commit.dropFirst()), 42] {
            XCTAssertEqual(parse(asset, commitish: commitish), .failure(.metadataInvalid), "\(String(describing: commitish))")
        }
    }

    func testPrereleaseMustBeTrueAndDraftFalse() {
        let asset = [EngineReleaseFixture.asset(digest: goodDigest)]
        for prerelease: Any? in [false, nil, 1, "true"] {
            XCTAssertEqual(parse(asset, prerelease: prerelease), .failure(.metadataInvalid), "\(String(describing: prerelease))")
        }
        for draft: Any? in [true, nil, 0, "false"] {
            XCTAssertEqual(parse(asset, draft: draft), .failure(.metadataInvalid), "\(String(describing: draft))")
        }
    }

    func testArchitectureSelectsItsOwnAssetAndIntelStaysClosed() throws {
        let assets = [EngineReleaseFixture.asset(name: "xash3d-fwgs-apple-amd64.tar.xz", digest: goodDigest),
                      EngineReleaseFixture.asset(digest: goodDigest)]
        XCTAssertEqual(try parse(assets, architecture: .amd64).get().asset.name, "xash3d-fwgs-apple-amd64.tar.xz")
        XCTAssertEqual(try parse(assets, architecture: .arm64).get().asset.name, "xash3d-fwgs-apple-arm64.tar.xz")
        XCTAssertFalse(EngineInstallCapability.amd64Enabled, "D5: Intel closed until G3")
        XCTAssertNil(EngineInstallCapability.check(.arm64))
        XCTAssertEqual(EngineInstallCapability.check(.amd64), .unsupportedArchitecture)
        XCTAssertNil(EngineInstallCapability.check(.amd64, amd64Enabled: true))
    }

    func testMissingOrMalformedDigestFailsClosed() {
        XCTAssertEqual(parse([EngineReleaseFixture.asset(digest: nil)]), .failure(.digestMissing))
        XCTAssertEqual(parse([EngineReleaseFixture.asset(digest: NSNull())]), .failure(.digestMissing))
        let bad: [Any] = ["sha256:" + String(repeating: "AB", count: 32), "sha512:" + String(repeating: "a", count: 64),
                          "sha256:" + String(repeating: "a", count: 63), String(repeating: "a", count: 64), 42]
        for digest in bad {
            XCTAssertEqual(parse([EngineReleaseFixture.asset(digest: digest)]), .failure(.digestInvalid), "\(digest)")
        }
    }

    func testSizeMustBeAPositiveNumberUpTo100MB() throws {
        for size: Any in [Int64(0), Int64(-1), EngineReleaseSource.maxAssetSize + 1, true, "1234"] {
            XCTAssertEqual(parse([EngineReleaseFixture.asset(size: size, digest: goodDigest)]), .failure(.sizeTooLarge),
                           "\(size)")
        }
        XCTAssertEqual(try parse([EngineReleaseFixture.asset(size: EngineReleaseSource.maxAssetSize,
                                                             digest: goodDigest)]).get().asset.size,
                       100 * 1024 * 1024)
    }

    func testAssetNameAndURLMustBeExact() {
        XCTAssertEqual(parse([EngineReleaseFixture.asset(name: "xash3d-fwgs-apple-arm64.tar.gz", digest: goodDigest)]),
                       .failure(.assetNotFound))
        XCTAssertEqual(parse([EngineReleaseFixture.asset(digest: goodDigest), EngineReleaseFixture.asset(digest: goodDigest)]),
                       .failure(.assetAmbiguous))
        let name = EngineArchitecture.arm64.assetName
        let cases: [(String, EngineInstallFailure)] = [
            ("http://github.com/FWGS/xash3d-fwgs/releases/download/continuous/" + name, .insecureURL),
            ("https://evil.example/FWGS/xash3d-fwgs/releases/download/continuous/" + name, .hostNotAllowed("evil.example")),
            ("https://github.com/someone/xash3d-fwgs/releases/download/continuous/" + name, .urlNotAllowed),
            ("https://github.com/FWGS/xash3d-fwgs/releases/download/v0.21/" + name, .urlNotAllowed),
        ]
        for (url, failure) in cases {
            XCTAssertEqual(parse([EngineReleaseFixture.asset(digest: goodDigest, url: url)]), .failure(failure), url)
        }
        XCTAssertEqual(parse([EngineReleaseFixture.asset(digest: goodDigest)], tag: "v0.21"), .failure(.metadataInvalid))
        XCTAssertEqual(parse([EngineReleaseFixture.asset(digest: goodDigest)],
                             html: "https://github.com/fork/xash3d-fwgs/releases/tag/continuous"), .failure(.metadataInvalid))
        XCTAssertEqual(EngineReleaseParser.parse(Data("not json".utf8), architecture: .arm64), .failure(.metadataInvalid))
    }

    // MARK: Network (T-E-N1, T-E-N2, T-E-RD1)

    func testDownloadHostAllowlistAndHTTPSOnly() throws {
        for host in ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"] {
            XCTAssertNil(EngineReleaseSource.checkDownloadHost(try XCTUnwrap(URL(string: "https://\(host)/a"))), host)
        }
        let rejected: [(String, EngineInstallFailure)] = [
            ("http://github.com/a", .insecureURL),
            ("https://api.github.com/a", .hostNotAllowed("api.github.com")),
            ("https://github.com.evil.example/a", .hostNotAllowed("github.com.evil.example")),
            ("https://github.com:8443/a", .hostNotAllowed("github.com")),
            ("https://u:p@github.com/a", .hostNotAllowed("github.com")),
        ]
        for (text, failure) in rejected {
            XCTAssertEqual(EngineReleaseSource.checkDownloadHost(try XCTUnwrap(URL(string: text))), failure, text)
        }
        XCTAssertTrue(EngineReleaseSource.isAllowedAPI(EngineReleaseSource.apiURL))
        XCTAssertFalse(EngineReleaseSource.isAllowedAPI(try XCTUnwrap(URL(string:
            "https://api.github.com/repos/fork/xash3d-fwgs/releases/tags/continuous"))))
    }

    func testRedirectGuardRejectionIsTypedAndWinsOverCancellationAndGenericErrors() throws {
        let download = EngineRedirectGuard(allowsRedirects: true)
        XCTAssertTrue(download.evaluate(URL(string: "https://release-assets.githubusercontent.com/x")))
        XCTAssertNil(download.rejected)
        XCTAssertFalse(download.evaluate(URL(string: "https://evil.example/x")))
        XCTAssertEqual(download.rejected, .redirectRejected("evil.example"))
        XCTAssertEqual(EngineInstallFailure.redirectRejected("evil.example").code, "security:redirectHost")
        let insecure = EngineRedirectGuard(allowsRedirects: true)
        XCTAssertFalse(insecure.evaluate(URL(string: "http://github.com/x")))
        XCTAssertEqual(insecure.rejected, .insecureURL)
        let api = EngineRedirectGuard(allowsRedirects: false)
        XCTAssertFalse(api.evaluate(URL(string: "https://github.com/x")))
        XCTAssertEqual(api.rejected, .redirectRejected("github.com"))

        // Order: guard rejection → cancellation → install failure → generic network failure.
        let rejection = EngineInstallFailure.redirectRejected("evil.example")
        XCTAssertEqual(EngineNetwork.classify(URLError(.cancelled), rejection: rejection, fallback: .downloadFailed)
                       as? EngineInstallFailure, rejection)
        XCTAssertEqual(EngineNetwork.classify(CancellationError(), rejection: rejection, fallback: .downloadFailed)
                       as? EngineInstallFailure, rejection)
        XCTAssertTrue(EngineNetwork.classify(URLError(.cancelled), rejection: nil, fallback: .downloadFailed)
                      is CancellationError)
        XCTAssertTrue(EngineNetwork.classify(CancellationError(), rejection: nil, fallback: .downloadFailed)
                      is CancellationError)
        XCTAssertEqual(EngineNetwork.classify(EngineInstallFailure.sizeTooLarge, rejection: nil, fallback: .downloadFailed)
                       as? EngineInstallFailure, .sizeTooLarge)
        XCTAssertEqual(EngineNetwork.classify(URLError(.notConnectedToInternet), rejection: nil,
                                              fallback: .metadataUnavailable) as? EngineInstallFailure,
                       .metadataUnavailable)
    }

    // MARK: Archive allowlist (T-E-X1 – T-E-X3, AC-E41, AC-E41b)

    private func entries(_ extra: [EngineArchiveEntry] = [], dropping: Set<String> = []) -> [EngineArchiveEntry] {
        FakeEngineArchive(package: EngineInstallFixture.upstreamPackage()).entries
            .filter { !dropping.contains($0.path) } + extra
    }

    func testRealPackageWithTheSixExtrasIsAccepted() throws {
        let plan = try EngineArchiveLayout.validate(entries(), architecture: .arm64).get()
        for extra in ["xash-clang-format", "libmenu_tui.dylib", "xrcon-tui", "mdldec", "activities.txt",
                      "valve/extras.pk3"] {
            XCTAssertTrue(plan.contains(extra), extra)
        }
        XCTAssertTrue(plan.contains("SDL2.framework/Versions/A/Headers/SDL_video.h"))
        XCTAssertTrue(plan.contains("SDL2.framework/Versions/Current/SDL2"))
        XCTAssertTrue(plan.contains("SDL2.framework/Resources/CMake/sdl2-config.cmake"))
        XCTAssertTrue(plan.contains("valve/dlls/hl_arm64.dylib"))
        XCTAssertFalse(plan.contains("libref_soft.dylib"))
    }

    func testAnyOtherRootValveOrFrameworkFileIsRejected() {
        let extras = ["./xrcon", "./mdldec2", "./valve/extras2.pk3", "./valve/maps/c1a0.bsp", "./README.txt",
                      "./valve/cl_dlls/client_amd64.dylib", "./valve/cl_dlls/menu.dylib", "./valve/liblist.gam",
                      "./SDL2.framework/evil.dylib", "./SDL2.framework/Versions/A/evil", "./SDL2.framework/Versions/B/SDL2",
                      "./SDL2.framework/Versions/A/Headers/evil.dylib", "./SDL2.framework/Versions/A/Headers/sub/SDL.h",
                      "./SDL2.framework/Versions/A/Resources/other.txt", "./SDL2.framework/Versions/A/Headers/SDL-x.h",
                      "./SDL2.framework/Versions/Current/_CodeSignature/CodeDirectory", "./xash3d"]
        for path in extras {
            XCTAssertEqual(EngineArchiveLayout.validate(entries([EngineArchiveEntry(path: path, type: .regular)]),
                                                        architecture: .arm64),
                           .failure(.unsafeArchive(path)), path)
        }
        for folder in ["./cstrike/", "./SDL2.framework/Versions/B/", "./SDL2.framework/Modules/", "./valve/maps/"] {
            XCTAssertEqual(EngineArchiveLayout.validate(entries([EngineArchiveEntry(path: folder, type: .directory)]),
                                                        architecture: .arm64), .failure(.unsafeArchive(folder)), folder)
        }
    }

    func testScanRejectsTraversalLinksDevicesAndFifos() {
        for path in ["/etc/passwd", "../evil", "./../evil", "valve/../../evil", "valve//dlls", "SDL2.framework/\u{7}x"] {
            let result = EngineArchiveLayout.validate(entries([EngineArchiveEntry(path: path, type: .regular)]),
                                                      architecture: .arm64)
            guard case .failure(.unsafeArchive) = result else { return XCTFail("\(path): \(result)") }
        }
        for type in [EngineArchiveEntryType.symbolicLink, .hardLink, .characterDevice, .blockDevice, .fifo, .socket,
                     .unknown] {
            XCTAssertEqual(EngineArchiveLayout.validate(
                entries([EngineArchiveEntry(path: "./SDL2.framework/Versions/A/Headers/SDL_x.h", type: type)]),
                architecture: .arm64), .failure(.unsafeArchive("./SDL2.framework/Versions/A/Headers/SDL_x.h")), type.rawValue)
        }
    }

    func testRequiredModulesAndFrameworkFilesMustBePresent() throws {
        XCTAssertEqual(EngineArchiveLayout.validate(entries(dropping: ["./libmenu.dylib"]), architecture: .arm64),
                       .failure(.missingExpectedFile("libmenu.dylib")))
        XCTAssertEqual(EngineArchiveLayout.validate(entries(dropping: ["./SDL2.framework/Versions/A/SDL2"]),
                                                    architecture: .arm64),
                       .failure(.missingExpectedFile("SDL2.framework/Versions/A/SDL2")))
        let withoutLibraries = try EngineArchiveLayout.validate(
            entries(dropping: ["./valve/cl_dlls/client_arm64.dylib", "./valve/dlls/hl_arm64.dylib", "./xrcon-tui"]),
            architecture: .arm64).get()
        XCTAssertFalse(withoutLibraries.contains("valve/dlls/hl_arm64.dylib"), "optional")
        XCTAssertTrue(try EngineArchiveLayout.validate(entries([EngineArchiveEntry(path: "./libref_soft.dylib",
                                                                                   type: .regular)]),
                                                       architecture: .arm64).get().contains("libref_soft.dylib"))
    }

    func testRealBundlePathMapping() {
        XCTAssertEqual(EngineArchiveLayout.gameLibraries(architecture: .arm64), [
            EngineGameLibrary(source: "valve/cl_dlls/client_arm64.dylib", bundle: "Contents/MacOS/cl_dlls/client_arm64.dylib",
                              gamedirRelative: "cl_dlls/client_arm64.dylib"),
            EngineGameLibrary(source: "valve/dlls/hl_arm64.dylib", bundle: "Contents/MacOS/dlls/hl_arm64.dylib",
                              gamedirRelative: "dlls/hl_arm64.dylib"),
        ])
        XCTAssertFalse(EngineArchiveLayout.gameLibraries(architecture: .arm64).contains { $0.bundle.contains("Resources") })
        XCTAssertEqual(EngineArchiveLayout.gameLibraries(architecture: .amd64).map(\.bundle),
                       ["Contents/MacOS/cl_dlls/client_amd64.dylib", "Contents/MacOS/dlls/hl_amd64.dylib"])
        XCTAssertEqual(EngineArchiveLayout.bundleFramework, "Contents/MacOS/SDL2.framework")
    }

    func testTarListingTypesComeFromTheVerboseLine() throws {
        let names = "./\n./s\n./f\n./h\n./p\n./d/sp ace\n"
        let verbose = """
        drwxr-xr-x  0 user staff       0 20 Kas 23:55 ./
        lrwxr-xr-x  0 user staff       0 20 Kas 23:55 ./s -> f
        -rw-r--r--  0 user staff       2 20 Kas 23:55 ./f
        hrw-r--r--  0 user staff       0 20 Kas 23:55 ./h link to ./f
        prw-r--r--  0 user staff       0 20 Kas 23:55 ./p
        -rw-r--r--  0 user staff       2 20 Kas 23:55 ./d/sp ace

        """
        let parsed = try XCTUnwrap(EngineTarListing.parse(names: names, verbose: verbose))
        XCTAssertEqual(parsed.map(\.type), [.directory, .symbolicLink, .regular, .hardLink, .fifo, .regular])
        XCTAssertNil(EngineTarListing.parse(names: "./a\n./b\n", verbose: "-rw-r--r-- 0 u g 1 x ./a\n"))
        XCTAssertEqual(EngineTarListing.parse(names: "./a\n", verbose: "-rw-r--r-- 0 u g 1 x ./a -> b\n")?.first?.type,
                       .unknown)
    }

    // MARK: State machine (T-E-ST1, AC-E7, AC-E79)

    func testStateMachineDefinesTheMainPathAndRejectsEverythingElse() {
        let path: [EngineInstallPhase] = [.idle, .checking, .confirm, .downloading, .verifyingDigest, .extracting,
                                          .verifyingSignature, .preflightPermission, .preflightProcess, .backingUp,
                                          .installing, .awaitingIdentityRepair, .verifyingIdentity, .completed, .idle]
        for (from, to) in zip(path, path.dropFirst()) {
            XCTAssertTrue(EngineInstallStateMachine.canTransition(from: from, to: to), "\(from)->\(to)")
        }
        XCTAssertFalse(EngineInstallStateMachine.canTransition(from: .backingUp, to: .rollingBack),
                       "a backup failure changed nothing: failed, not rolled back")
        XCTAssertTrue(EngineInstallStateMachine.canTransition(from: .backingUp, to: .failed))
        XCTAssertTrue(EngineInstallStateMachine.canTransition(from: .installing, to: .failed))
        XCTAssertFalse(EngineInstallStateMachine.canTransition(from: .installing, to: .cancelled))
        XCTAssertFalse(EngineInstallStateMachine.canTransition(from: .idle, to: .installing))
        XCTAssertEqual(EngineInstallPhase.allCases.filter(\.isCancellable), [.downloading, .extracting])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let from = EngineInstallPhase.allCases.randomElement(using: &generator)!
            let to = EngineInstallPhase.allCases.randomElement(using: &generator)!
            XCTAssertEqual(EngineInstallStateMachine.canTransition(from: from, to: to),
                           EngineInstallStateMachine.next(from).contains(to))
            if from.isTerminal { XCTAssertEqual(EngineInstallStateMachine.next(from), [.idle]) }
        }
        for phase in EngineInstallPhase.allCases {
            XCTAssertEqual(EngineInstallStateMachine.next(phase).contains(.cancelled), phase.isCancellable, phase.rawValue)
        }
    }

    // MARK: Eligibility (AC-E1)

    func testInstallIsOfferedOnlyForUnsupportedWithZeroOrAbsentIdentity() {
        XCTAssertTrue(EngineInstallEligibility.isOffered(.fixture(support: .no, raw: .zero)))
        XCTAssertTrue(EngineInstallEligibility.isOffered(.fixture(support: .no, raw: .absent)))
        XCTAssertFalse(EngineInstallEligibility.isOffered(.fixture(support: .no, raw: .nonzero)))
        XCTAssertFalse(EngineInstallEligibility.isOffered(.fixture(support: .yes, raw: .zero)))
        XCTAssertFalse(EngineInstallEligibility.isOffered(.fixture(support: .unknown, raw: .zero)))
        XCTAssertFalse(EngineInstallEligibility.isOffered(.fixture(support: .no, raw: .zero, process: .running)))
    }

    // MARK: Identity verification (T-E-IB2, T-E-IB3, T-E-K3, T-E-K4, T-E-ID2, T-E-CID2)

    private func snapshot(_ global: RawIdentityState, _ gamedir: RawIdentityState, equal: Bool,
                          cid: String? = "abcd…0123") -> EngineIdentitySnapshot {
        EngineIdentitySnapshot(global: global, gamedir: gamedir, rawEqual: equal, cidMasked: cid)
    }

    func testIdentityRepairedOnlyFromARepairableBeforeToAHealthyAfter() {
        let healthy = snapshot(.nonzero, .nonzero, equal: true, cid: "3333…4444")
        for before in [snapshot(.zero, .zero, equal: false), snapshot(.absent, .absent, equal: false, cid: nil),
                       snapshot(.unreadable, .nonzero, equal: false, cid: nil), snapshot(.nonzero, .absent, equal: false)] {
            let result = EngineIdentityVerifier.evaluate(before: before, after: healthy)
            XCTAssertEqual(result.verification, .identityRepaired, "\(before)")
            XCTAssertTrue(result.mayClaimSupported)
            XCTAssertEqual(result.phase, .completed)
        }
        // Both non-zero but different raw before: not repairable, not healthy.
        XCTAssertEqual(EngineIdentityVerifier.evaluate(before: snapshot(.nonzero, .nonzero, equal: false),
                                                       after: healthy).verification, .notVerified)
    }

    func testAlreadyHealthyAndNotVerifiedNeverClaimRepair() {
        let healthy = snapshot(.nonzero, .nonzero, equal: true)
        let already = EngineIdentityVerifier.evaluate(before: healthy, after: healthy)
        XCTAssertEqual(already.verification, .alreadyHealthy)
        XCTAssertTrue(already.mayClaimSupported)
        for after in [snapshot(.nonzero, .nonzero, equal: false), snapshot(.zero, .zero, equal: false),
                      snapshot(.nonzero, .absent, equal: false), snapshot(.unreadable, .nonzero, equal: false)] {
            for before in [healthy, snapshot(.absent, .absent, equal: false)] {
                let result = EngineIdentityVerifier.evaluate(before: before, after: after)
                XCTAssertEqual(result.verification, .notVerified, "\(before) → \(after)")
                XCTAssertFalse(result.mayClaimSupported, "AC-E82: no supported/healthy claim")
                XCTAssertEqual(result.phase, .completedWithWarning)
            }
        }
    }

    func testChangedCIDIsBeforeAndAfterMaskedOnly() {
        let result = EngineIdentityVerifier.evaluate(before: snapshot(.absent, .absent, equal: false, cid: "1111…2222"),
                                                     after: snapshot(.nonzero, .nonzero, equal: true, cid: "3333…4444"))
        XCTAssertTrue(result.cidChanged)
        XCTAssertEqual(result.cidBefore, "1111…2222")
        XCTAssertEqual(result.cidAfter, "3333…4444")
        let full = EngineIdentityVerifier.evaluate(before: snapshot(.zero, .zero, equal: false,
                                                                    cid: String(repeating: "a", count: 32)),
                                                   after: snapshot(.nonzero, .nonzero, equal: true, cid: "ABCD…0123"))
        XCTAssertNil(full.cidBefore, "a full CID is never carried")
        XCTAssertNil(full.cidAfter, "only the strict lowercase mask")
    }

    func testIdentityReaderComparesRawValuesNotFileBytes() {
        let home = MacIdentityFixture.home
        let gamedir = URL(fileURLWithPath: "/Games/valve", isDirectory: true)
        let raw: UInt64 = 0x0A0B_0C0D_0E0F_1011
        let files = FakeFileProbe()
        files.setFile(home.path + "/.config/.xash_id", HexID.format(raw ^ IdentityLocation.homeMask))
        files.setFile(gamedir.path + "/.xash_id", HexID.format(raw ^ IdentityLocation.gamedirMask) + "\n")
        let reader = LocalEngineIdentityReader(files: files)
        let same = reader.snapshot(home: home, gamedir: gamedir)
        XCTAssertTrue(same.isHealthy, "different bytes, same raw (AC-E58)")
        XCTAssertNotNil(EngineInstallPrivacy.strictMasked(same.cidMasked))
        files.setFile(gamedir.path + "/.xash_id", HexID.format((raw + 1) ^ IdentityLocation.gamedirMask))
        XCTAssertFalse(reader.snapshot(home: home, gamedir: gamedir).rawEqual)
        files.set(home.path + "/.config/.xash_id", .link)
        XCTAssertEqual(reader.snapshot(home: home, gamedir: gamedir).global, .unreadable)
    }

    // MARK: Privacy (T-E-LG1, T-E-LG2)

    func testOnlyTheStrictMaskIsAcceptedAnywhere() {
        XCTAssertEqual(EngineInstallPrivacy.strictMasked("abcd…0123"), "abcd…0123")
        for bad in ["0123456789abcdef0123456789abcdef", "0123456789ABCDEF", "abcd...0123", "ABCD…0123", "abcd…012",
                    "…", "abcd…01g3", ""] {
            XCTAssertNil(EngineInstallPrivacy.strictMasked(bad), bad)
        }
        XCTAssertNil(EngineInstallConfirmation(acceptedCIDWarning: true, cidBefore: "0123456789abcdef0123456789abcdef")
            .cidBefore, "a full CID is dropped, not stored")
        XCTAssertEqual(EngineInstallConfirmation(acceptedCIDWarning: true, cidBefore: "abcd…0123").cidBefore, "abcd…0123")

        var log = EngineInstallLog()
        log.add([(.cid, "0123456789abcdef0123456789abcdef")])
        log.add([(.cid, "1122334455667788")])
        log.add([(.cid, "abcd…0123")])
        log.add([(.note, "1122334455667788"), (.error, "0123456789ABCDEF0123456789abcdef")])
        log.add([(.stage, "downloading"), (.error, "a b\nc")])
        log.add([(.commit, EngineReleaseFixture.commit)])
        XCTAssertEqual(log.lines, ["cid=withheld", "cid=withheld", "cid=abcd…0123", "note=withheld error=withheld",
                                   "stage=downloading error=a_b_c", "commit=" + EngineReleaseFixture.commit])
    }

    // MARK: Commands, tool output and time limits (T-E-U1, T-E-ER1, T-E-PR2)

    func testCommandsAreFixedArgvWithTheArchiveOnStdin() throws {
        let folder = try XCTUnwrap(UpdatePath(URL(fileURLWithPath: "/tmp/stage dir;x")))
        let app = try XCTUnwrap(UpdatePath(URL(fileURLWithPath: "/tmp/stage dir/Xash3D-FWGS.app")))
        let expected: [(EngineCommand, [String])] = [
            (.tarList, ["/usr/bin/tar", "-tJf", "-"]),
            (.tarListVerbose, ["/usr/bin/tar", "-tvJf", "-"]),
            (.tarExtract(into: folder), ["/usr/bin/tar", "--no-xattrs", "--no-acls", "--no-fflags", "--no-mac-metadata",
                                         "-xJf", "-", "-C", "/tmp/stage dir;x"]),
            (.signFramework(app), ["/usr/bin/codesign", "--force", "--sign", "-", "--", app.value]),
            (.signApp(app), ["/usr/bin/codesign", "--force", "--sign", "-", "--", app.value]),
            (.verifySignature(app), ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--", app.value]),
        ]
        for (command, argv) in expected {
            XCTAssertEqual(command.argv, argv)
            XCTAssertTrue(EngineCommandAllowlist.isAllowed(argv), argv.joined(separator: " "))
        }
        XCTAssertFalse(EngineCommand.signApp(app).argv.contains("--deep"), "nested libraries keep upstream bytes")
        XCTAssertFalse(EngineCommandAllowlist.isAllowed(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--",
                                                         app.value]))
        XCTAssertFalse(EngineCommandAllowlist.isAllowed(["/usr/bin/tar", "-tJf", "/tmp/a.tar.xz"]), "path, not stdin")
        XCTAssertFalse(EngineCommandAllowlist.isAllowed(["/bin/sh", "-c", "tar -xJf x"]))
        XCTAssertFalse(EngineCommandAllowlist.isAllowed(["/usr/bin/tar", "-xJf", "-", "-C", "/tmp"]))
        XCTAssertNil(UpdatePath(URL(fileURLWithPath: "/tmp/a$(touch pwned)")), "command substitution refused")
    }

    func testTarAndCodesignPassTheArchiveBytesAndNeverTheToolOutput() async throws {
        let runner = RecordingEngineRunner()
        runner.outputs = ["-tJf": "./\n./xash3d\n",
                          "-tvJf": "drwxr-xr-x 0 u g 0 d ./\n-rwxr-xr-x 0 u g 5 d ./xash3d\n"]
        let archive = Data("archive-bytes".utf8)
        let entries = try await TarEngineArchive(runner: runner).list(archive)
        XCTAssertEqual(entries.map(\.type), [.directory, .regular])
        XCTAssertEqual(runner.inputs, [archive, archive], "both listings read the same bytes")

        let secret = "tar: /Users/ercanatay/Library/secret: token=hunter2 /private/var/folders/x/y"
        runner.outputs = ["-tJf": secret, "-tvJf": secret]
        runner.status = 2
        do {
            _ = try await TarEngineArchive(runner: runner).list(archive)
            XCTFail("listed")
        } catch let error as EngineToolError {
            XCTAssertEqual(error, EngineToolError(tool: "tar", category: .archiveRejected, exitStatus: 2))
            XCTAssertEqual(error.logNote, "tar:archiveRejected:exit2")
            for leak in ["ercanatay", "/Users", "/private", "hunter2", "token"] {
                XCTAssertFalse(String(describing: error).contains(leak), leak)
            }
        }
        runner.status = 1
        do {
            try await ProcessEngineCodeSigner(runner: runner).verify(URL(fileURLWithPath: "/tmp/a.app"))
            XCTFail("verified")
        } catch let error as EngineToolError {
            XCTAssertEqual(error.category, .signatureInvalid)
            XCTAssertFalse(String(describing: error).contains("hunter2"))
        }
    }

    func testProcessTimeLimitsMapToTheirStage() async {
        let runner = RecordingEngineRunner()
        runner.error = CommandError.timedOut
        do {
            _ = try await TarEngineArchive(runner: runner).list(Data())
            XCTFail("listed")
        } catch {
            XCTAssertEqual(error as? EngineInstallFailure, .timeout(.extraction))
            XCTAssertEqual(EngineInstallFailure.timeout(.extraction).code, "timeout:extraction")
        }
        do {
            try await ProcessEngineCodeSigner(runner: runner).signApp(URL(fileURLWithPath: "/tmp/a.app"))
            XCTFail("signed")
        } catch {
            XCTAssertEqual(error as? EngineInstallFailure, .timeout(.install))
            XCTAssertEqual(EngineInstallFailure.timeout(.install).code, "timeout:install")
        }
        runner.error = CommandError.cancelled
        do {
            try await TarEngineArchive(runner: runner).extract(Data(), into: URL(fileURLWithPath: "/tmp/x"))
            XCTFail("extracted")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: Backup inventory (T-E-RT1 – T-E-RT3)

    private func makeBackups(_ stamps: [String]) throws -> (TempDirectory, EngineBackupStore) {
        let temp = try TempDirectory()
        for stamp in stamps {
            try temp.write("Xash3D-FWGS-\(stamp).app/Contents/Info.plist", "x")
            try temp.write("identity-\(stamp)/homeConfig.xash_id", "x")
            try temp.write("libs-\(stamp)/valve-dlls-hl_arm64.dylib", "x")
            try temp.write("manifest-\(stamp).json", "{}")
        }
        try temp.write("notes.txt", "unrelated")
        return (temp, EngineBackupStore(root: temp.url))
    }

    func testInventoryKeepsTheNewestThreeAndDeletesNothingByItself() throws {
        let stamps = ["20261101-100000", "20261102-100000", "20261103-100000", "20261104-100000",
                      "20261104-100000-0a1b2c3d"]
        let (temp, store) = try makeBackups(stamps)
        let before = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).sorted()
        let inventory = try store.inventory()
        XCTAssertEqual(inventory.groups.map(\.stamp), stamps.sorted(by: >))
        XCTAssertEqual(inventory.kept.map(\.stamp), ["20261104-100000-0a1b2c3d", "20261104-100000", "20261103-100000"])
        XCTAssertEqual(inventory.pruneCandidates.map(\.stamp), ["20261102-100000", "20261101-100000"])
        XCTAssertTrue(inventory.groups.allSatisfy { $0.items.count == 4 && $0.hasManifest })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).sorted(), before,
                       "listing deletes nothing")
        XCTAssertEqual(EngineBackupStore.stamp(of: "Xash3D-FWGS-20261101-100000.app"), "20261101-100000")
        XCTAssertNil(EngineBackupStore.stamp(of: "notes.txt"))
    }

    func testDeletionNeedsATokenForPruneCandidatesOfTheCurrentInventory() throws {
        let stamps = ["20261101-100000", "20261102-100000", "20261103-100000", "20261104-100000", "20261105-100000"]
        let (temp, store) = try makeBackups(stamps)
        let inventory = try store.inventory()
        XCTAssertEqual(store.deleteBackups(nil), .failure(.confirmationRequired))
        XCTAssertEqual(store.confirmDeletion(of: ["20261105-100000"], in: inventory).map(\.stamps),
                       .failure(.confirmationRequired), "kept groups cannot be confirmed")
        XCTAssertEqual(store.confirmDeletion(of: [], in: inventory).map(\.stamps), .failure(.confirmationRequired))
        let token = try store.confirmDeletion(of: ["20261101-100000"], in: inventory).get()

        // A changed folder invalidates the token.
        try temp.write("manifest-20261106-100000.json", "{}")
        XCTAssertEqual(store.deleteBackups(token), .failure(.confirmationRequired))
        try FileManager.default.removeItem(at: temp.url.appendingPathComponent("manifest-20261106-100000.json"))

        let report = try store.deleteBackups(token).get()
        XCTAssertEqual(report, EngineBackupDeletionReport(removed: ["20261101-100000"], failed: [:]))
        XCTAssertEqual(report.status, .success)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        XCTAssertFalse(remaining.contains { $0.contains("20261101-100000") })
        XCTAssertTrue(remaining.contains("manifest-20261102-100000.json"), "only the confirmed group")
        XCTAssertTrue(remaining.contains("notes.txt"))
    }

    func testAGroupThatCannotBeRemovedKeepsItsManifest() throws {
        let stamps = ["20261101-100000", "20261102-100000", "20261103-100000", "20261104-100000", "20261105-100000"]
        let (temp, _) = try makeBackups(stamps)
        let files = RecordingEngineFiles()
        files.fail = { operation, url in
            operation == "remove" && url.lastPathComponent.hasPrefix("libs-20261101") ? .posix(EPERM) : nil
        }
        let store = EngineBackupStore(root: temp.url, files: files)
        let token = try store.confirmDeletion(of: ["20261101-100000", "20261102-100000"], in: try store.inventory()).get()
        let report = try store.deleteBackups(token).get()
        XCTAssertEqual(report.status, .partialFailure, "never reported as a success (AC-E98)")
        XCTAssertEqual(report.removed, ["20261102-100000"], "removed and failed are reported apart")
        XCTAssertEqual(report.failed, ["20261101-100000": .removeFailed])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        XCTAssertTrue(remaining.contains("manifest-20261101-100000.json"), "metadata kept (AC-E79d)")
        XCTAssertTrue(remaining.contains("libs-20261101-100000"))
    }
}

/// Records engine commands and their stdin; answers with fixed outputs keyed by the first flag.
final class RecordingEngineRunner: EngineCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [EngineCommand] = []
    private var recordedInputs: [Data] = []
    var status: Int32 = 0
    var outputs: [String: String] = [:]
    var error: (any Error)?

    var commands: [EngineCommand] { lock.withLock { recorded } }
    var inputs: [Data] { lock.withLock { recordedInputs } }

    func run(_ command: EngineCommand, input: Data?) async throws -> CommandOutput {
        XCTAssertTrue(EngineCommandAllowlist.isAllowed(command.argv))
        lock.withLock {
            recorded.append(command)
            if let input { recordedInputs.append(input) }
        }
        if let error { throw error }
        return CommandOutput(status: status, output: outputs[command.argv[1]] ?? "")
    }
}
