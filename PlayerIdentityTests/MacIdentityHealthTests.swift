import XCTest
@testable import PlayerIdentity

/// §73 macOS hardware identity health: static capability (K1–K4), raw identity state, decision table, engine path
/// rules, actions, privacy and the "no write" guarantees (U1–U20; v2.25 T-D, T-P, T-F, T-M, T-O).
final class MacIdentityHealthTests: XCTestCase {
    private let home = MacIdentityFixture.home
    private var app: String { EnginePaths.defaultApp.path }

    private func probe(engine: MachOFixture.Options? = MachOFixture.upstream, library: MachOFixture.Options? = nil,
                       identity: String? = nil) -> FakeFileProbe {
        let files = FakeFileProbe()
        if let engine {
            files.installEngine(executable: MachOFixture.thin(engine), library: library.map(MachOFixture.thin))
        }
        if let identity { files.setFile(home.path + "/.config/.xash_id", identity) }
        return files
    }

    private func check(_ files: FakeFileProbe, running: Bool = false, process: EngineProcessState? = nil,
                       gamedir: URL? = nil, now: @escaping @Sendable () -> Date = { Date() },
                       clock: MonotonicClock = .system) -> MacIdentityReport {
        let detector = FakeGameDetector(running: running)
        detector.processState = process
        return MacIdentityChecker(files: files, detector: detector, home: home, now: now, clock: clock)
            .check(engineApp: EnginePaths.defaultApp, gamedir: gamedir)
    }

    private func inEnglish<T>(_ body: () throws -> T) rethrows -> T {
        try L10n.$bundle.withValue(L10n.languageBundle("en")!, operation: body)
    }

    // MARK: Decision table (§73.3, U1–U4)

    func testDecisionTableRows() {
        typealias Row = (StaticSupport, RawIdentityState, MacIdentityState, MacIdentityFinding, MacIdentityAction)
        let rows: [Row] = [
            (.yes, .nonzero, .supported, .healthy, .none),
            (.no, .nonzero, .unknown, .nonzeroWithoutEvidence, .downloadEngine),
            (.yes, .zero, .unknown, .zero, .regenerate),
            (.yes, .absent, .unknown, .notGenerated, .regenerate),
            (.no, .zero, .unsupported, .unsupported, .downloadEngine),
            (.no, .absent, .unsupported, .unsupported, .downloadEngine),
            (.yes, .unreadable, .unknown, .identityUnreadable, .none),
            (.no, .unreadable, .unknown, .identityUnreadable, .none),
        ]
        for (support, raw, state, finding, action) in rows {
            let decision = MacIdentityDecision.decide(support: support, raw: raw)
            XCTAssertEqual(decision.state, state, "\(support) + \(raw)")
            XCTAssertEqual(decision.finding, finding, "\(support) + \(raw)")
            XCTAssertEqual(decision.action, action, "\(support) + \(raw)")
        }
        for raw in RawIdentityState.allCases {
            let decision = MacIdentityDecision.decide(support: .unknown, raw: raw, failure: .unreadable)
            XCTAssertEqual(decision.state, .unknown)
            XCTAssertEqual(decision.finding, .engineUnverifiable)
            XCTAssertEqual(decision.action, .none)
        }
        let notFound = MacIdentityDecision.decide(support: .unknown, raw: .zero, failure: .engineNotFound)
        XCTAssertEqual(notFound.finding, .engineNotFound)
        XCTAssertEqual(notFound.action, .none)   // T-F5 / AC-9: an unverifiable package never offers the download
        for support in StaticSupport.allCases {
            for raw in RawIdentityState.allCases + [nil] {
                let running = MacIdentityDecision.decide(process: .running, support: support, raw: raw)
                XCTAssertEqual(running.state, .unknown)
                XCTAssertEqual(running.finding, .engineRunning)
                XCTAssertEqual(running.action, .none)
                let unavailable = MacIdentityDecision.decide(process: .unavailable, support: support, raw: raw)
                XCTAssertEqual(unavailable.state, .unknown)
                XCTAssertEqual(unavailable.finding, .processUnavailable)
                XCTAssertEqual(unavailable.action, .none)
            }
        }
    }

    func testU1SupportedNonzeroIsHealthy() throws {
        let report = check(probe(identity: MacIdentityFixture.nonzeroFile))
        XCTAssertEqual(report.staticSupport, .yes)
        XCTAssertEqual(report.evidence.count, 4)
        XCTAssertEqual(report.rawState, .nonzero)
        XCTAssertEqual(report.state, .supported)
        XCTAssertEqual(report.finding, .healthy)
        XCTAssertEqual(report.cidMasked, RawIdentityReader.mask(MacIdentityFixture.nonzeroCID))
        XCTAssertEqual(report.engineVersion, "0.21")
        XCTAssertEqual(report.engineHashShort?.count, 12)
        try inEnglish {
            let card = MacIdentityPresentation(report: report, checking: false, engineRunning: false)
            // T-D1: indicators, never a uniqueness claim.
            XCTAssertEqual(card.message, "A non-zero identity and static hardware-identity indicators were found. "
                           + "Uniqueness was not directly verified.")
            XCTAssertEqual(card.stateLabel, "Indicators found")
            XCTAssertFalse(card.message.lowercased().contains("is unique"))
            XCTAssertNil(card.regenerate)
            XCTAssertFalse(card.showsDownload)
        }
    }

    func testTD2NoEvidenceButNonzeroIsUnknownAndRecommendsACompatibleEngine() throws {
        let report = check(probe(engine: MachOFixture.installed, identity: MacIdentityFixture.nonzeroFile))
        XCTAssertEqual(report.staticSupport, .no)
        XCTAssertEqual(report.state, .unknown)   // AC-2: no longer `supported`
        XCTAssertEqual(report.finding, .nonzeroWithoutEvidence)
        XCTAssertEqual(report.action, .downloadEngine)
        try inEnglish {
            let card = MacIdentityPresentation(report: report, checking: false, engineRunning: false)
            XCTAssertEqual(card.stateLabel, "Uncertain")
            XCTAssertEqual(card.tone, .warning)
            XCTAssertTrue(card.showsDownload)
            XCTAssertNil(card.regenerate)
            XCTAssertTrue(card.message.contains("static hardware-identity verification was not possible"))
            XCTAssertTrue(card.message.contains("A compatible engine is recommended."))
        }
    }

    func testU3SupportedZeroOffersRegenerate() throws {
        let report = check(probe(identity: MacIdentityFixture.zeroFile))
        XCTAssertEqual(report.rawState, .zero)
        XCTAssertEqual(report.state, .unknown)
        XCTAssertEqual(report.action, .regenerate)
        XCTAssertEqual(report.cidMasked, RawIdentityReader.mask(MacIdentityFixture.zeroCID))
        try inEnglish {
            let card = MacIdentityPresentation(report: report, checking: false, engineRunning: false)
            XCTAssertEqual(card.regenerate, .init(enabled: true, blockedReason: nil))
            XCTAssertFalse(card.showsDownload)
            XCTAssertTrue(card.notes.contains { $0.contains("shares the same CID") })
            XCTAssertTrue(card.notes.contains { $0.contains("playeridentityctl diagnose --macos-identity") })
        }
    }

    func testSupportedAbsentOffersRegenerateAsFirstLaunch() {
        let report = check(probe(identity: nil))
        XCTAssertEqual(report.rawState, .absent)
        XCTAssertEqual(report.finding, .notGenerated)
        XCTAssertEqual(report.action, .regenerate)
        XCTAssertNil(report.cidMasked)
    }

    func testU4UnsupportedZeroAndAbsentOfferOnlyTheDownloadLink() throws {
        for identity in [MacIdentityFixture.zeroFile, nil] {
            let report = check(probe(engine: MachOFixture.installed, identity: identity))
            XCTAssertEqual(report.state, .unsupported)
            XCTAssertEqual(report.action, .downloadEngine)
            try inEnglish {
                let card = MacIdentityPresentation(report: report, checking: false, engineRunning: false)
                XCTAssertTrue(card.showsDownload)
                XCTAssertNil(card.regenerate)   // U10
                XCTAssertEqual(card.message, "The installed engine does not support the macOS hardware identity. "
                               + "A compatible version is required.")
            }
        }
    }

    // MARK: Static evidence (§73.4)

    func testU9OnlyK1ToK3IsNotYes() {
        let options = MachOFixture.Options(ioKit: true, coreFoundation: true, symbols: ["_IOServiceMatching"], cStrings: [])
        let report = check(probe(engine: options, identity: MacIdentityFixture.zeroFile))
        XCTAssertEqual(report.evidence.count, 3)
        XCTAssertFalse(report.evidence.platformSerialString)
        XCTAssertEqual(report.staticSupport, .no)
        XCTAssertEqual(report.state, .unsupported)
    }

    func testK4NeedsAtLeastTwoMoreItems() {
        var evidence = CapabilityEvidence(platformSerialString: true)
        XCTAssertEqual(evidence.support, .no)
        evidence.ioKitLinked = true
        XCTAssertEqual(evidence.support, .no)
        evidence.coreFoundationLinked = true
        XCTAssertEqual(evidence.support, .yes)
        XCTAssertEqual(CapabilityEvidence(ioKitLinked: true, coreFoundationLinked: true, ioRegistryAccess: true).support, .no)
    }

    func testEvidenceIsMergedAcrossTheExecutableAndTheEngineLibrary() {
        let launcher = MachOFixture.Options(coreFoundation: true, symbols: ["_SDL_Init"])
        let engine = MachOFixture.Options(ioKit: true, symbols: ["_IORegistryEntryFromPath"],
                                          cStrings: ["IOPlatformSerialNumber"])
        let report = check(probe(engine: launcher, library: engine, identity: MacIdentityFixture.nonzeroFile))
        XCTAssertEqual(report.evidence, CapabilityEvidence(ioKitLinked: true, coreFoundationLinked: true,
                                                           ioRegistryAccess: true, platformSerialString: true))
        XCTAssertEqual(report.finding, .healthy)
    }

    func testFatBinarySlicesAreScanned() {
        let files = FakeFileProbe()
        files.installEngine(executable: MachOFixture.fat([MachOFixture.thin(MachOFixture.installed),
                                                          MachOFixture.thin(MachOFixture.upstream)]))
        files.setFile(home.path + "/.config/.xash_id", MacIdentityFixture.nonzeroFile)
        let report = check(files)
        XCTAssertEqual(report.staticSupport, .yes)
        XCTAssertEqual(report.finding, .healthy)
    }

    func testRealMachOOfTheTestHostParses() throws {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let scanner = MachOCapabilityScanner(files: LocalFileProbe())
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        XCTAssertNoThrow(try scanner.scan(executable, deadline: deadline))
        XCTAssertEqual(try scanner.sha256Short(executable, deadline: deadline).count, 12)
    }

    func testVersionTextIsNotADecisionInput() {
        let old = FakeFileProbe()
        old.installEngine(executable: MachOFixture.thin(MachOFixture.upstream), version: "0.1")
        let new = FakeFileProbe()
        new.installEngine(executable: MachOFixture.thin(MachOFixture.installed), version: "99.0-hardware-id")
        XCTAssertEqual(check(old).staticSupport, .yes)
        XCTAssertEqual(check(new).staticSupport, .no)
    }

    // MARK: Unknown paths (U5–U7, limits)

    func testU5UnreadableOrNonMachOBinaryIsUnknownWithoutAction() {
        let unreadable = FakeFileProbe()
        unreadable.installEngine(executable: Data())
        unreadable.set(app + "/Contents/MacOS/xash3d", .unreadable(size: 4096))
        let notMachO = probe(engine: nil)
        notMachO.installEngine(executable: Data("#!/bin/sh\necho hi\n".utf8))
        for (files, failure) in [(unreadable, CapabilityFailure.unreadable), (notMachO, .notMachO)] {
            files.setFile(home.path + "/.config/.xash_id", MacIdentityFixture.zeroFile)
            let report = check(files)
            XCTAssertEqual(report.staticSupport, .unknown)
            XCTAssertEqual(report.capabilityFailure, failure)
            XCTAssertEqual(report.state, .unknown)
            XCTAssertEqual(report.finding, .engineUnverifiable)
            XCTAssertEqual(report.action, .none)
        }
    }

    func testU6MissingEngineIsUnknownEngineNotFound() throws {
        let report = check(probe(engine: nil, identity: MacIdentityFixture.zeroFile))
        XCTAssertEqual(report.state, .unknown)
        XCTAssertEqual(report.capabilityFailure, .engineNotFound)
        XCTAssertEqual(report.finding, .engineNotFound)
        try inEnglish {
            let card = MacIdentityPresentation(report: report, checking: false, engineRunning: false)
            XCTAssertEqual(card.message, "Engine not found. Check the engine path.")
            XCTAssertNil(card.regenerate)
            XCTAssertFalse(card.showsDownload)   // v2.25 §3.2: an unverifiable package never offers the download
        }
    }

    func testU7BinaryAbove512MBIsUnknownWithoutReadingIt() {
        let files = FakeFileProbe()
        files.installEngine(executable: Data())
        files.set(app + "/Contents/MacOS/xash3d", .sized(512 * 1024 * 1024 + 1))
        let report = check(files)
        XCTAssertEqual(report.capabilityFailure, .tooLarge)
        XCTAssertEqual(report.state, .unknown)
        XCTAssertFalse(files.reads.contains(app + "/Contents/MacOS/xash3d"))
    }

    func testTM7ScanTimeLimitUsesTheMonotonicClock() {
        let monotonic = SteppingMonotonicClock(step: .seconds(2))
        let report = check(probe(identity: MacIdentityFixture.nonzeroFile), clock: monotonic.clock)
        XCTAssertEqual(report.capabilityFailure, .timeout)
        XCTAssertEqual(report.staticSupport, .unknown)
        XCTAssertEqual(report.state, .unknown)
    }

    func testWallClockJumpsDoNotAffectTheScanLimit() {
        // The wall clock jumps an hour per reading (and the other test goes backwards): the limit ignores it.
        for step in [3600.0, -3600.0] {
            let wall = SteppingClock(step: step)
            let report = check(probe(identity: MacIdentityFixture.nonzeroFile), now: { wall.now() },
                               clock: SteppingMonotonicClock().clock)
            XCTAssertNil(report.capabilityFailure, "\(step)")
            XCTAssertEqual(report.state, .supported, "\(step)")
        }
    }

    func testTS9ASingleBlockingReadEndsAsTimeoutNotSuccess() {
        let monotonic = SteppingMonotonicClock()
        let files = probe(identity: MacIdentityFixture.nonzeroFile)
        // One read "blocks" for 5 s (it cannot be interrupted): the check after it turns the scan into `unknown`.
        let once = OnceFlag()
        files.onRead = { path in
            if path.hasSuffix("/MacOS/xash3d"), once.fire() { monotonic.advance(.seconds(5)) }
        }
        let report = check(files, clock: monotonic.clock)
        XCTAssertEqual(report.capabilityFailure, .timeout)
        XCTAssertEqual(report.state, .unknown)
        XCTAssertNil(report.engineHashShort)
    }

    func testTM8CancellationStopsAtTheNextChunk() async throws {
        let files = probe(identity: MacIdentityFixture.nonzeroFile)
        let scanner = MachOCapabilityScanner(files: files, clock: SteppingMonotonicClock().clock)
        guard case .success(let bundle) = EnginePaths.inspect(EnginePaths.defaultApp, files: files) else {
            return XCTFail("inspect")
        }
        let readsBefore = files.reads.count
        // The first read cancels the scanning task; the scan stops at the next chunk boundary.
        files.onRead = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let result = await Task.detached { scanner.check(bundle) }.value
        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertEqual(result.support, .unknown)
        XCTAssertNil(result.engineHashShort)
        XCTAssertEqual(files.reads.count - readsBefore, 1)

        files.onRead = nil
        let cancelledBeforeStart = await Task.detached { () -> CapabilityResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return scanner.check(bundle)
        }.value
        XCTAssertEqual(cancelledBeforeStart.failure, .cancelled)
    }

    func testSymbolicLinksInsideTheBundleAreNotFollowed() {
        let files = probe(identity: MacIdentityFixture.nonzeroFile)
        files.set(app + "/Contents/MacOS/xash3d", .link)
        XCTAssertEqual(check(files).capabilityFailure, .symbolicLink)
        let linkedApp = FakeFileProbe()
        linkedApp.set(app, .link)
        XCTAssertEqual(check(linkedApp).capabilityFailure, .symbolicLink)
    }

    // MARK: Raw identity (U8)

    func testU8IdentityFileFormatAndSizeRules() {
        let cases: [(String, RawIdentityState)] = [
            ("10331C2DCE4C91DB", .zero),
            ("10331c2dce4c91db\r\n", .zero),
            ("00000000000000AB\n", .nonzero),
            (" 10331C2DCE4C91DB", .unreadable),
            ("10331C2DCE4C91D", .unreadable),
            ("10331C2DCE4C91DBX", .unreadable),
            ("not hex at all!!", .unreadable),
            (String(repeating: "0", count: 65), .unreadable),
        ]
        for (text, state) in cases {
            let files = FakeFileProbe()
            files.setFile(home.path + "/.config/.xash_id", text)
            XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: files).state, state, text)
        }
    }

    func testFirstValidFileWinsAndGamedirUsesItsMask() {
        let files = FakeFileProbe()
        files.setFile(home.path + "/.config/.xash_id", "garbage")
        files.setFile(home.path + "/.xash_id", MacIdentityFixture.nonzeroFile)
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: files).state, .nonzero)

        let gameOnly = FakeFileProbe()
        let gamedir = URL(fileURLWithPath: "/data/valve", isDirectory: true)
        gameOnly.setFile("/data/valve/.xash_id", HexID.format(IdentityLocation.gamedirMask))
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: gamedir, files: gameOnly).state, .zero)
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: gameOnly).state, .absent)
    }

    func testLinkedOrFolderIdentityIsUnreadable() {
        let files = FakeFileProbe()
        files.set(home.path + "/.config/.xash_id", .link)
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: files).state, .unreadable)
    }

    func testMasking() {
        XCTAssertEqual(RawIdentityReader.mask("0123456789abcdef0123456789abcdef"), "0123…cdef")
        XCTAssertEqual(RawIdentityReader.mask("short"), "…")
    }

    // MARK: Engine running (U11, §73.5.3)

    func testTP1EngineRunningScansHashesAndReadsNothing() throws {
        let files = probe(identity: MacIdentityFixture.zeroFile)
        let report = check(files, running: true)
        XCTAssertEqual(report.state, .unknown)
        XCTAssertEqual(report.finding, .engineRunning)
        XCTAssertEqual(report.action, .none)
        XCTAssertEqual(report.processState, .running)
        XCTAssertNil(report.rawState)
        XCTAssertNil(report.cidMasked)
        XCTAssertNil(report.engineHashShort)
        XCTAssertNil(report.capabilityFailure)
        XCTAssertEqual(report.staticSupport, .unknown)
        XCTAssertEqual(report.evidence, CapabilityEvidence())
        XCTAssertFalse(report.staticChecked)
        XCTAssertNil(report.packageReadability)
        // Nothing was opened, read or even inspected: no static scan, no hash, no raw identity.
        XCTAssertEqual(files.reads, [])
        XCTAssertEqual(files.inspected, [])
        try inEnglish {
            let card = MacIdentityPresentation(report: report, checking: false, engineRunning: true)
            XCTAssertEqual(card.message, "The engine is running, so it was not scanned and the identity was not read. "
                           + "Quit the engine, then press Refresh.")
            XCTAssertNil(card.regenerate)
            XCTAssertFalse(card.showsDownload)
            XCTAssertFalse(card.details.contains { $0.hasPrefix("Static evidence") })
        }
    }

    func testTP2AndTP3UnavailableProcessStateIsNeverNotRunning() throws {
        let files = probe(identity: MacIdentityFixture.zeroFile)
        let report = check(files, process: .unavailable)
        XCTAssertEqual(report.state, .unknown)
        XCTAssertEqual(report.finding, .processUnavailable)
        XCTAssertEqual(report.action, .none)   // never `.regenerate`
        XCTAssertNil(report.rawState)
        XCTAssertNil(report.engineHashShort)
        XCTAssertEqual(files.reads, [])
        XCTAssertEqual(files.inspected, [])
        try inEnglish {
            let card = MacIdentityPresentation(report: report, checking: false, engineRunning: false)
            XCTAssertTrue(card.message.hasPrefix("The engine process state could not be verified"))
            XCTAssertTrue(card.message.contains("Regeneration is blocked."))
            XCTAssertNil(card.regenerate)
        }
    }

    func testTP4ConfigEditDetectorKeepsItsYesNoAnswer() {
        // Legacy detectors get the compatible tri-state default; the yes/no answer itself is unchanged.
        let legacy = FakeGameDetector(running: true)
        XCTAssertTrue(legacy.isGameRunning())
        XCTAssertEqual(legacy.engineProcessState(), .running)
        legacy.isRunning = false
        XCTAssertFalse(legacy.isGameRunning())
        XCTAssertEqual(legacy.engineProcessState(), .notRunning)
        // An unavailable tri-state does not change the config-edit answer.
        legacy.processState = .unavailable
        XCTAssertFalse(legacy.isGameRunning())
        XCTAssertEqual(legacy.engineProcessState(), .unavailable)
        // The real detector: the tri-state agrees with the yes/no answer whenever it is reliable.
        let system = SystemGameProcessDetector()
        switch system.engineProcessState() {
        case .running: XCTAssertTrue(system.isGameRunning())
        case .notRunning: XCTAssertFalse(system.isGameRunning())
        case .unavailable: XCTFail("the test process list must be readable")
        }
    }

    func testU11EngineRunningBlocksRegenerateOnACurrentZeroReport() throws {

        let zero = check(probe(identity: MacIdentityFixture.zeroFile))
        try inEnglish {
            let card = MacIdentityPresentation(report: zero, checking: false, engineRunning: true)
            XCTAssertEqual(card.regenerate, .init(enabled: false, blockedReason: "Quit the engine first."))
        }
    }

    // MARK: Engine path (§73.6, U17, U18)

    func testU17SymbolicLinkOverrideIsRejectedAndTheDefaultIsUsed() {
        let files = FakeFileProbe()
        files.installEngine(at: "/Users/tester/Games/Xash3D.app", executable: MachOFixture.thin(MachOFixture.upstream))
        files.set("/Users/tester/Linked.app", .link)
        let resolution = EnginePathResolution.resolve(override: "/Users/tester/Linked.app", files: files,
                                                      forbiddenRoots: EnginePaths.forbiddenRoots(home: home, dataRoot: nil))
        XCTAssertEqual(resolution.app, EnginePaths.defaultApp)
        XCTAssertFalse(resolution.isOverride)
        XCTAssertEqual(resolution.rejectedOverride, .symbolicLink)

        // A link in a parent folder is rejected too (the resolved path differs).
        files.set("/Users/tester/Games", .link)
        XCTAssertEqual(EnginePaths.validateOverride(URL(fileURLWithPath: "/Users/tester/Games/Xash3D.app"), files: files,
                                                    forbiddenRoots: []), .symbolicLink)
    }

    func testU18OverrideInsideDataOrIdentityFoldersIsRejected() {
        let files = FakeFileProbe()
        let dataRoot = URL(fileURLWithPath: "/Users/tester/Library/Application Support/Xash3D FWGS", isDirectory: true)
        let inside = dataRoot.appendingPathComponent("valve/Xash3D.app").path
        files.installEngine(at: inside, executable: MachOFixture.thin(MachOFixture.upstream))
        files.installEngine(at: "/Users/tester/.config/Xash3D.app", executable: MachOFixture.thin(MachOFixture.upstream))
        let roots = EnginePaths.forbiddenRoots(home: home, dataRoot: dataRoot)
        XCTAssertEqual(EnginePaths.validateOverride(URL(fileURLWithPath: inside), files: files, forbiddenRoots: roots),
                       .insideDataFolder)
        XCTAssertEqual(EnginePaths.validateOverride(URL(fileURLWithPath: "/Users/tester/.config/Xash3D.app"), files: files,
                                                    forbiddenRoots: roots), .insideDataFolder)
        XCTAssertEqual(EnginePathResolution.resolve(override: inside, files: files, forbiddenRoots: roots).rejectedOverride,
                       .insideDataFolder)
    }

    func testOverrideRules() {
        let files = FakeFileProbe()
        files.installEngine(at: "/Users/tester/Games/Xash3D.app", executable: MachOFixture.thin(MachOFixture.upstream))
        files.set("/Users/tester/Games/Folder/x", .file(Data()))
        files.set("/Users/tester/Games/Empty.app/Contents/Info.plist", .file(Data()))
        files.set("/Users/tester/Games/Empty.app/Contents/MacOS", .directory)
        let valid = EnginePathResolution.resolve(override: "/Users/tester/Games/Xash3D.app", files: files, forbiddenRoots: [])
        XCTAssertTrue(valid.isOverride)
        XCTAssertNil(valid.rejectedOverride)
        XCTAssertEqual(EnginePaths.validateOverride(URL(fileURLWithPath: "/Users/tester/Games/Folder"), files: files,
                                                    forbiddenRoots: []), .notAppBundle)
        XCTAssertEqual(EnginePaths.validateOverride(URL(fileURLWithPath: "/Users/tester/Games/Empty.app"), files: files,
                                                    forbiddenRoots: []), .missingExecutable)
        XCTAssertEqual(EnginePaths.validateOverride(URL(fileURLWithPath: "/Users/tester/Nope.app"), files: files,
                                                    forbiddenRoots: []), .notFound)
        XCTAssertEqual(EnginePathResolution.resolve(override: nil, files: files, forbiddenRoots: []).app, EnginePaths.defaultApp)
        XCTAssertEqual(EnginePaths.defaultApp.path, "/Applications/Xash3D-FWGS.app")
    }

    func testRealOverrideWithLocalProbe() throws {
        let temp = try TempDirectory()
        let base = temp.physicalURL
        let appURL = base.appendingPathComponent("Engine.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try MachOFixture.writeExecutable(MachOFixture.thin(MachOFixture.upstream),
                                          to: appURL.appendingPathComponent("Contents/MacOS/xash3d"))
        let link = base.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: appURL)
        let probe = LocalFileProbe()
        XCTAssertNil(EnginePaths.validateOverride(appURL, files: probe, forbiddenRoots: []))
        XCTAssertEqual(EnginePaths.validateOverride(link, files: probe, forbiddenRoots: []), .symbolicLink)
        guard case .success(let bundle) = EnginePaths.inspect(appURL, files: probe) else { return XCTFail("inspect") }
        XCTAssertEqual(MachOCapabilityScanner(files: probe).check(bundle).support, .yes)
    }

    // MARK: Link allowlist (U13)

    func testU13OnlyTheOfficialHTTPSReleasePageIsAllowed() {
        XCTAssertEqual(EngineDownloadLink.url.absoluteString, "https://github.com/FWGS/xash3d-fwgs/releases/tag/continuous")
        XCTAssertTrue(EngineDownloadLink.isAllowed(EngineDownloadLink.url))
        for text in ["http://github.com/FWGS/xash3d-fwgs/releases/tag/continuous",
                     "https://github.com/FWGS/xash3d-fwgs/releases",
                     "https://example.com/FWGS/xash3d-fwgs/releases/tag/continuous",
                     "file:///Applications/Xash3D-FWGS.app"] {
            XCTAssertFalse(EngineDownloadLink.isAllowed(URL(string: text)!), text)
        }
    }

    // MARK: Regenerator (U12)

    func testRegeneratorOnlyLaunchesTheEngineAndOnlyWhenOffered() async throws {
        let files = probe(identity: MacIdentityFixture.zeroFile)
        let launcher = FakeAppLauncher()
        let detector = FakeGameDetector()
        let regenerator = MacIdentityRegenerator(files: files, detector: detector, launcher: launcher)
        try await regenerator.regenerate(report: check(files))
        XCTAssertEqual(launcher.calls, [.init(app: EnginePaths.defaultApp, arguments: [])])

        let unsupported = probe(engine: MachOFixture.installed, identity: MacIdentityFixture.zeroFile)
        do {
            try await MacIdentityRegenerator(files: unsupported, detector: detector, launcher: launcher)
                .regenerate(report: check(unsupported))
            XCTFail("not offered")
        } catch let error as MacIdentityRegenerateError {
            XCTAssertEqual(error, .notOffered)
        }
        detector.isRunning = true
        do {
            try await regenerator.regenerate(report: check(files))
            XCTFail("engine running")
        } catch let error as MacIdentityRegenerateError {
            XCTAssertEqual(error, .engineRunning)
        }
        XCTAssertEqual(launcher.calls.count, 1)
    }

    func testRegeneratorSurfacesLaunchFailures() async {
        struct Boom: Error {}
        let files = probe(identity: MacIdentityFixture.zeroFile)
        let regenerator = MacIdentityRegenerator(files: files, detector: FakeGameDetector(),
                                                 launcher: FakeAppLauncher(failure: Boom()))
        do {
            try await regenerator.regenerate(report: check(files))
            XCTFail("expected a failure")
        } catch let error as MacIdentityRegenerateError {
            guard case .launchFailed = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Read-only on real files (U12, U20)

    func testU20CheckLeavesIdentityAndGameDataUnchanged() throws {
        let temp = try TempDirectory()
        let realHome = temp.physicalURL.appendingPathComponent("home", isDirectory: true)
        try temp.write("home/.config/.xash_id", MacIdentityFixture.zeroFile)
        try temp.write("home/Library/Application Support/Xash3D FWGS/valve/config.cfg", "name \"P\"\n")
        try temp.write("home/Library/Application Support/Xash3D FWGS/valve/.xash_id",
                       HexID.format(IdentityLocation.gamedirMask))
        let appURL = realHome.appendingPathComponent("Applications/Xash3D-FWGS.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try MachOFixture.writeExecutable(MachOFixture.thin(MachOFixture.upstream),
                                          to: appURL.appendingPathComponent("Contents/MacOS/xash3d"))
        let before = try MacIdentityFixture.tree(realHome)
        let checker = MacIdentityChecker(files: LocalFileProbe(), detector: FakeGameDetector(), home: realHome)
        let report = checker.check(engineApp: appURL, gamedir: realHome
            .appendingPathComponent("Library/Application Support/Xash3D FWGS/valve", isDirectory: true))
        XCTAssertEqual(report.finding, .zero)
        XCTAssertEqual(try MacIdentityFixture.tree(realHome), before)
    }

    // MARK: v2.25 file system errors (T-F1–T-F6, AC-8, AC-9)

    func testLstatErrorsOtherThanENOENTAreUnreadable() {
        XCTAssertEqual(LocalFileProbe.kind(forLstatError: ENOENT), .missing)
        for code in [EACCES, EPERM, EIO, ESTALE, ELOOP, ENAMETOOLONG, ENOTDIR] {
            XCTAssertEqual(LocalFileProbe.kind(forLstatError: code), .unreadable, "\(code)")
        }
    }

    func testTF1AndTF2IdentityAbsentOnlyWhenEveryLocationIsDefinitelyMissing() {
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: FakeFileProbe()).state, .absent)
        for path in [home.path + "/.config/.xash_id", home.path + "/.local/.xash_id", home.path + "/.xash_id"] {
            let files = FakeFileProbe()
            files.set(path, .inaccessible)
            XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: files).state, .unreadable, path)
        }
        let gamedir = URL(fileURLWithPath: "/data/valve", isDirectory: true)
        let game = FakeFileProbe()
        game.set("/data/valve/.xash_id", .inaccessible)
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: gamedir, files: game).state, .unreadable)
        // End to end: an inaccessible identity is `unknown` without action, never "absent → regenerate".
        let files = probe(identity: nil)
        files.set(home.path + "/.config/.xash_id", .inaccessible)
        let report = check(files)
        XCTAssertEqual(report.rawState, .unreadable)
        XCTAssertEqual(report.finding, .identityUnreadable)
        XCTAssertEqual(report.action, .none)
    }

    func testTF3DanglingLinkAndUnreadableFileAreUnreadable() {
        let files = FakeFileProbe()
        files.set(home.path + "/.config/.xash_id", .alias("/nowhere/.xash_id"))
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: files).state, .unreadable)
        let failing = FakeFileProbe()
        failing.set(home.path + "/.config/.xash_id", .unreadable(size: 17))
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: failing).state, .unreadable)
    }

    func testTF2RealPermissionDeniedIdentityFolderIsUnreadable() throws {
        let temp = try TempDirectory()
        let realHome = temp.physicalURL
        try temp.write(".config/.xash_id", MacIdentityFixture.nonzeroFile)
        let config = realHome.appendingPathComponent(".config", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: config.path) }
        let probe = LocalFileProbe()
        XCTAssertEqual(probe.kind(config.appendingPathComponent(".xash_id")), .unreadable)
        XCTAssertEqual(probe.kind(realHome.appendingPathComponent(".local/.xash_id")), .missing)
        XCTAssertEqual(RawIdentityReader.probe(home: realHome, gamedir: nil, files: probe).state, .unreadable)
    }

    func testTF5UnverifiablePackageIsUnknownNeverUnsupportedOrDownload() throws {
        let inaccessibleItems = [app, app + "/Contents", app + "/Contents/MacOS", app + "/Contents/Info.plist",
                                 app + "/Contents/MacOS/xash3d", app + "/Contents/MacOS/libxash.dylib"]
        for item in inaccessibleItems {
            let files = probe(engine: MachOFixture.installed, identity: MacIdentityFixture.zeroFile)
            files.set(item, .inaccessible)
            let report = check(files)
            XCTAssertEqual(report.staticSupport, .unknown, item)
            XCTAssertEqual(report.capabilityFailure, .unreadable, item)
            XCTAssertEqual(report.state, .unknown, item)
            XCTAssertEqual(report.finding, .engineUnverifiable, item)
            XCTAssertEqual(report.action, .none, item)
            XCTAssertEqual(report.packageReadability, .unverifiable, item)
            try inEnglish {
                let card = MacIdentityPresentation(report: report, checking: false, engineRunning: false)
                XCTAssertFalse(card.showsDownload, item)
                XCTAssertNil(card.regenerate, item)
                XCTAssertEqual(card.message, "The engine package could not be verified. Check the engine path and its "
                               + "file permissions.")
            }
        }
        XCTAssertEqual(EnginePaths.validateOverride(EnginePaths.defaultApp, files: {
            let files = FakeFileProbe()
            files.set(app, .inaccessible)
            return files
        }(), forbiddenRoots: []), .unreadable)
    }

    func testTF5RealUnreadableBundleIsUnverifiable() throws {
        let temp = try TempDirectory()
        let appURL = temp.physicalURL.appendingPathComponent("Locked/Engine.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try MachOFixture.writeExecutable(MachOFixture.thin(MachOFixture.installed),
                                          to: appURL.appendingPathComponent("Contents/MacOS/xash3d"))
        let locked = appURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        guard case .failure(let error) = EnginePaths.inspect(appURL, files: LocalFileProbe()) else {
            return XCTFail("a locked bundle must not inspect")
        }
        XCTAssertEqual(error, .unreadable)
        let report = MacIdentityChecker(files: LocalFileProbe(), detector: FakeGameDetector(), home: temp.physicalURL)
            .check(engineApp: appURL, gamedir: nil)
        XCTAssertEqual(report.finding, .engineUnverifiable)
        XCTAssertNotEqual(report.state, .unsupported)
        XCTAssertEqual(report.action, .none)
    }

    // MARK: v2.25 broken Mach-O (T-M3–T-M5, AC-10)

    private func corrupted(_ patch: (Data) -> Data) -> MacIdentityReport {
        let files = FakeFileProbe()
        files.installEngine(executable: patch(MachOFixture.thin(MachOFixture.installed)))
        files.setFile(home.path + "/.config/.xash_id", MacIdentityFixture.zeroFile)
        return check(files)
    }

    func testTM3ToTM5StructurallyBrokenMachOIsUnknownNeverNo() throws {
        let thin = MachOFixture.thin(MachOFixture.installed)
        let symtab = try XCTUnwrap(MachOFixture.commandOffset(thin, 0x2))
        let segment = try XCTUnwrap(MachOFixture.commandOffset(thin, 0x19))
        let dylib = try XCTUnwrap(MachOFixture.commandOffset(thin, 0xC))
        let patches: [(String, (Data) -> Data)] = [
            ("load commands larger than the file", { MachOFixture.patched($0, at: 20, 0x00FF_FFFF) }),
            ("command size past the load commands", { MachOFixture.patched($0, at: dylib + 4, 0x0010_0000) }),
            ("command count larger than the commands", { MachOFixture.patched($0, at: 16, 500) }),
            ("dylib name offset outside the command", { MachOFixture.patched($0, at: dylib + 8, 0xFFFF) }),
            ("dylib name offset inside the header", { MachOFixture.patched($0, at: dylib + 8, 4) }),
            ("string table outside the file", { MachOFixture.patched($0, at: symtab + 16, 0x7FFF_0000) }),
            ("string table size past the file", { MachOFixture.patched($0, at: symtab + 20, 0x7FFF_0000) }),
            ("symbol table outside the file", { MachOFixture.patched($0, at: symtab + 12, 0x0FFF_FFFF) }),
            ("section offset outside the file", { MachOFixture.patched($0, at: segment + 72 + 48, 0x7FFF_0000) }),
            ("section size past the file", { MachOFixture.patched($0, at: segment + 72 + 40, 0x7FFF_0000) }),
            ("section count larger than the command", { MachOFixture.patched($0, at: segment + 64, 9) }),
            ("segment file range past the file", { MachOFixture.patched($0, at: segment + 48, 0x7FFF_0000) }),
            ("unknown magic", { MachOFixture.patched($0, at: 0, 0xDEAD_BEEF) }),
        ]
        for (name, patch) in patches {
            let report = corrupted(patch)
            XCTAssertEqual(report.staticSupport, .unknown, name)
            XCTAssertEqual(report.capabilityFailure, .notMachO, name)
            XCTAssertEqual(report.state, .unknown, name)
            XCTAssertEqual(report.finding, .engineUnverifiable, name)
            XCTAssertEqual(report.action, .none, name)
        }
        // Control: the unpatched file is a valid binary without evidence → `no` → unsupported.
        XCTAssertEqual(corrupted { $0 }.state, .unsupported)
    }

    func testValidUnrelatedLoadCommandsAreSkipped() {
        var options = MachOFixture.upstream
        options.unrelatedCommand = true
        let files = probe(engine: options, identity: MacIdentityFixture.nonzeroFile)
        let report = check(files)
        XCTAssertNil(report.capabilityFailure)
        XCTAssertEqual(report.staticSupport, .yes)
        XCTAssertEqual(report.state, .supported)
    }

    // MARK: v2.25 containment (T-O1, T-O2, AC-12)

    func testTO1OverrideThroughALinkIntoTheDataRootIsRejected() {
        let files = FakeFileProbe()
        let dataRoot = URL(fileURLWithPath: "/Users/tester/Library/Application Support/Xash3D FWGS", isDirectory: true)
        files.installEngine(at: dataRoot.path + "/valve/Hidden.app", executable: MachOFixture.thin(MachOFixture.upstream))
        files.set("/Users/tester/Games", .alias(dataRoot.path + "/valve"))
        let roots = EnginePaths.forbiddenRoots(home: home, dataRoot: dataRoot)
        let alias = URL(fileURLWithPath: "/Users/tester/Games/Hidden.app", isDirectory: true)
        XCTAssertTrue(EnginePaths.isForbidden(alias, roots: roots, files: files))
        XCTAssertEqual(EnginePaths.validateOverride(alias, files: files, forbiddenRoots: roots), .insideDataFolder)
        let resolution = EnginePathResolution.resolve(override: alias.path, files: files, forbiddenRoots: roots)
        XCTAssertEqual(resolution.rejectedOverride, .insideDataFolder)
        XCTAssertEqual(resolution.app, EnginePaths.defaultApp)
        XCTAssertEqual(resolution.requestedPath, alias.path)
    }

    func testTO2ForbiddenRootReachedThroughALinkIsStillForbidden() {
        let files = FakeFileProbe()
        // The data root itself is a link to another volume; the candidate uses the physical path.
        files.set("/Users/tester/GameData", .alias("/Volumes/Games/Xash"))
        files.installEngine(at: "/Volumes/Games/Xash/valve/X.app", executable: MachOFixture.thin(MachOFixture.upstream))
        let roots = EnginePaths.forbiddenRoots(home: home,
                                               dataRoot: URL(fileURLWithPath: "/Users/tester/GameData", isDirectory: true))
        let candidate = URL(fileURLWithPath: "/Volumes/Games/Xash/valve/X.app", isDirectory: true)
        XCTAssertFalse(EnginePaths.isInside(candidate, roots[2]))   // lexically outside…
        XCTAssertEqual(EnginePaths.validateOverride(candidate, files: files, forbiddenRoots: roots),
                       .insideDataFolder)   // …physically inside
    }

    func testRealSymlinkAliasesCannotEscapeTheContainmentCheck() throws {
        let temp = try TempDirectory()
        let base = temp.physicalURL
        let dataRoot = base.appendingPathComponent("Data", isDirectory: true)
        let appURL = dataRoot.appendingPathComponent("valve/Engine.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try MachOFixture.writeExecutable(MachOFixture.thin(MachOFixture.upstream),
                                          to: appURL.appendingPathComponent("Contents/MacOS/xash3d"))
        let aliasFolder = base.appendingPathComponent("Games", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasFolder, withDestinationURL: dataRoot.appendingPathComponent("valve"))
        let rootLink = base.appendingPathComponent("DataLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: dataRoot)
        let probe = LocalFileProbe()
        // Candidate through an alias folder.
        XCTAssertEqual(EnginePaths.validateOverride(aliasFolder.appendingPathComponent("Engine.app"), files: probe,
                                                    forbiddenRoots: [dataRoot]), .insideDataFolder)
        // Forbidden root given through a link; the candidate uses the physical path.
        XCTAssertEqual(EnginePaths.validateOverride(appURL, files: probe, forbiddenRoots: [rootLink]), .insideDataFolder)
        // Outside every root, the same bundle is fine.
        XCTAssertNil(EnginePaths.validateOverride(appURL, files: probe, forbiddenRoots: [base.appendingPathComponent("Other")]))
        // `/var` is a link to `/private/var`: the lexical temp path is refused as a link, the physical one is not.
        if temp.url.path != base.path {
            XCTAssertEqual(EnginePaths.validateOverride(temp.url.appendingPathComponent("Data/valve/Engine.app"),
                                                        files: probe, forbiddenRoots: []), .symbolicLink)
        }
    }

    // MARK: v2.25 wording (T-L1, T-L2, AC-17)

    func testTL1NoUniquenessClaimInEnglishOrTurkish() throws {
        let keys = L10nKey.allCases.filter { $0.rawValue.hasPrefix("macIdentity.") }
        for language in ["en", "tr"] {
            let bundle = try XCTUnwrap(L10n.languageBundle(language))
            L10n.$bundle.withValue(bundle) {
                for key in keys {
                    let text = L10n.text(key).lowercased()
                    for forbidden in ["unique identity", "is unique", "benzersiz", "new random", "yeni rastgele",
                                      "guarantee", "garanti"] {
                        XCTAssertFalse(text.contains(forbidden), "\(language) \(key.rawValue): \(forbidden)")
                    }
                    if text.contains("unique") || text.contains("tekil") {
                        XCTAssertTrue(text.contains("not directly verified") || text.contains("doğrudan doğrulanmadı"),
                                      "\(language) \(key.rawValue) mentions uniqueness without the negation")
                    }
                }
            }
        }
    }

    // MARK: Review round 2 — process first with an explicit override (finding 1)

    func testExplicitOverrideIsNeitherValidatedNorReadWhileRunningOrUnavailable() {
        for state in [EngineProcessState.running, .unavailable] {
            let files = FakeFileProbe()
            files.installEngine(at: "/Users/tester/Games/Xash3D.app", executable: MachOFixture.thin(MachOFixture.upstream))
            files.setFile(home.path + "/.config/.xash_id", MacIdentityFixture.zeroFile)
            let detector = FakeGameDetector()
            detector.processState = state
            let result = MacIdentityChecker(files: files, detector: detector, home: home)
                .check(override: "/Users/tester/Games/../Games/Xash3D.app", forbiddenRoots: [], gamedir: nil)
            XCTAssertEqual(files.reads, [], "\(state)")
            XCTAssertEqual(files.inspected, [], "\(state)")
            XCTAssertFalse(result.resolution.validated)
            XCTAssertNil(result.resolution.rejectedOverride)
            XCTAssertEqual(result.resolution.requestedPath, "/Users/tester/Games/Xash3D.app")   // lexical only
            XCTAssertEqual(result.report.finding, state == .running ? .engineRunning : .processUnavailable)
            XCTAssertNil(result.report.rawState)
            XCTAssertNil(result.report.engineHashShort)
        }
        // Closed: now the override is validated and used.
        let files = FakeFileProbe()
        files.installEngine(at: "/Users/tester/Games/Xash3D.app", executable: MachOFixture.thin(MachOFixture.upstream))
        files.setFile(home.path + "/.config/.xash_id", MacIdentityFixture.nonzeroFile)
        let closed = MacIdentityChecker(files: files, detector: FakeGameDetector(), home: home)
            .check(override: "/Users/tester/Games/Xash3D.app", forbiddenRoots: [], gamedir: nil)
        XCTAssertTrue(closed.resolution.validated)
        XCTAssertTrue(closed.resolution.isOverride)
        XCTAssertEqual(closed.report.finding, .healthy)
    }

    // MARK: Review round 2 — identity parent links (finding 2)

    func testIdentityBehindAParentLinkIsUnreadable() {
        // `~/.config` is a link: the file "exists" through it, but it is not followed.
        let config = FakeFileProbe()
        config.set(home.path + "/.config", .alias("/Volumes/Other/config"))
        config.setFile(home.path + "/.config/.xash_id", MacIdentityFixture.nonzeroFile)
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: config).state, .unreadable)
        // `~/.local` is an unknown link.
        let local = FakeFileProbe()
        local.set(home.path + "/.local", .link)
        local.setFile(home.path + "/.local/.xash_id", MacIdentityFixture.nonzeroFile)
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: local).state, .unreadable)
        // The home folder itself is a link.
        let linkedHome = FakeFileProbe()
        linkedHome.set(home.path, .alias("/Volumes/Other/home"))
        linkedHome.setFile(home.path + "/.xash_id", MacIdentityFixture.nonzeroFile)
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: linkedHome).state, .unreadable)
        // A folder above the game folder is a link.
        let game = FakeFileProbe()
        game.set("/data", .alias("/Volumes/Other/data"))
        game.setFile("/data/valve/.xash_id", HexID.format(IdentityLocation.gamedirMask))
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: URL(fileURLWithPath: "/data/valve", isDirectory: true),
                                               files: game).state, .unreadable)
        // Control: no link → read normally.
        let plain = FakeFileProbe()
        plain.setFile(home.path + "/.config/.xash_id", MacIdentityFixture.nonzeroFile)
        XCTAssertEqual(RawIdentityReader.probe(home: home, gamedir: nil, files: plain).state, .nonzero)
    }

    func testRealParentLinksAreRejectedButSystemAliasesAreNot() throws {
        let temp = try TempDirectory()
        let base = temp.physicalURL
        let probe = LocalFileProbe()
        // A real home whose `.config` is a user link to another folder.
        let realConfig = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: realConfig, withIntermediateDirectories: true)
        try Data(MacIdentityFixture.nonzeroFile.utf8).write(to: realConfig.appendingPathComponent(".xash_id"))
        let linkedHome = base.appendingPathComponent("home-linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedHome.appendingPathComponent(".config"),
                                                   withDestinationURL: realConfig)
        XCTAssertEqual(probe.kind(linkedHome.appendingPathComponent(".config/.xash_id")), .regularFile)
        XCTAssertEqual(RawIdentityReader.probe(home: linkedHome, gamedir: nil, files: probe).state, .unreadable)
        // A home that is itself a user link.
        let homeLink = base.appendingPathComponent("home-alias", isDirectory: true)
        let target = base.appendingPathComponent("home-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent(".config"), withIntermediateDirectories: true)
        try Data(MacIdentityFixture.nonzeroFile.utf8).write(to: target.appendingPathComponent(".config/.xash_id"))
        try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: target)
        XCTAssertEqual(RawIdentityReader.probe(home: homeLink, gamedir: nil, files: probe).state, .unreadable)
        XCTAssertEqual(RawIdentityReader.probe(home: target, gamedir: nil, files: probe).state, .nonzero)
        // A game folder below a linked data folder.
        let realData = base.appendingPathComponent("real-data/valve", isDirectory: true)
        try FileManager.default.createDirectory(at: realData, withIntermediateDirectories: true)
        try Data(HexID.format(IdentityLocation.gamedirMask).utf8).write(to: realData.appendingPathComponent(".xash_id"))
        let dataLink = base.appendingPathComponent("data-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: dataLink, withDestinationURL: realData.deletingLastPathComponent())
        let emptyHome = base.appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        XCTAssertEqual(RawIdentityReader.probe(home: emptyHome, gamedir: dataLink.appendingPathComponent("valve"),
                                               files: probe).state, .unreadable)
        XCTAssertEqual(RawIdentityReader.probe(home: emptyHome, gamedir: realData, files: probe).state, .zero)
        // The temporary folder written through the system alias `/var` (→ `/private/var`) is not a user link.
        let lexicalHome = temp.url.appendingPathComponent("target-lexical", isDirectory: true)
        try temp.write("target-lexical/.config/.xash_id", MacIdentityFixture.nonzeroFile)
        XCTAssertEqual(RawIdentityReader.probe(home: lexicalHome, gamedir: nil, files: probe).state, .nonzero)
        XCTAssertEqual(EnginePaths.systemCanonical("/var/folders/x"), "/private/var/folders/x")
        XCTAssertEqual(EnginePaths.systemCanonical("/tmp"), "/private/tmp")
        XCTAssertEqual(EnginePaths.systemCanonical("/variable/x"), "/variable/x")
    }

    // MARK: Review round 2 — Mach-O command and section consistency (finding 3)

    func testLoadCommandTotalsAlignmentAndFileBackedOffsetsAreChecked() throws {
        let thin = MachOFixture.thin(MachOFixture.installed)
        let ncmds = MachOCapabilityScanner.uint32(thin, 16, bigEndian: false)
        let sizeofcmds = MachOCapabilityScanner.uint32(thin, 20, bigEndian: false)
        let symtab = try XCTUnwrap(MachOFixture.commandOffset(thin, 0x2))
        let segment = try XCTUnwrap(MachOFixture.commandOffset(thin, 0x19))
        let dylib = try XCTUnwrap(MachOFixture.commandOffset(thin, 0xC))
        let dylibSize = MachOCapabilityScanner.uint32(thin, dylib + 4, bigEndian: false)
        let patches: [(String, (Data) -> Data)] = [
            ("one command fewer than declared bytes", { MachOFixture.patched($0, at: 16, ncmds - 1) }),
            ("no commands", { MachOFixture.patched($0, at: 16, 0) }),
            ("zero command bytes", { MachOFixture.patched($0, at: 20, 0) }),
            ("declared bytes past the last command", { MachOFixture.patched($0, at: 20, sizeofcmds + 8) }),
            ("command size not 4-byte aligned", { MachOFixture.patched($0, at: dylib + 4, dylibSize + 2) }),
            ("file-backed section at offset 0", { MachOFixture.patched($0, at: segment + 72 + 48, 0) }),
            ("string table at offset 0", { MachOFixture.patched($0, at: symtab + 16, 0) }),
            ("symbol table at offset 0", { MachOFixture.patched(MachOFixture.patched($0, at: symtab + 12, 1),
                                                                at: symtab + 8, 0) }),
        ]
        for (name, patch) in patches {
            let report = corrupted(patch)
            XCTAssertEqual(report.staticSupport, .unknown, name)
            XCTAssertEqual(report.capabilityFailure, .notMachO, name)
            XCTAssertEqual(report.state, .unknown, name)
            XCTAssertNotEqual(report.state, .unsupported, name)
        }
        // A zero-fill section may have offset 0 (no file contents).
        let zeroFill = corrupted { data in
            MachOFixture.patched(MachOFixture.patched(data, at: segment + 72 + 64, 0x1), at: segment + 72 + 48, 0)
        }
        XCTAssertNil(zeroFill.capabilityFailure)
        XCTAssertEqual(zeroFill.state, .unsupported)
    }

    // MARK: Review round 2 — cancellation stops before the identity (finding 4)

    func testCancelledCheckNeverReadsTheIdentity() async {
        let files = probe(identity: MacIdentityFixture.zeroFile)
        files.onRead = { path in
            if path.hasSuffix("/MacOS/xash3d") { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let checker = MacIdentityChecker(files: files, detector: FakeGameDetector(), home: home)
        let report = await Task.detached { checker.check(engineApp: EnginePaths.defaultApp, gamedir: nil) }.value
        XCTAssertEqual(report.capabilityFailure, .cancelled)
        XCTAssertEqual(report.state, .unknown)
        XCTAssertNil(report.rawState)
        XCTAssertNil(report.cidMasked)
        XCTAssertFalse(files.reads.contains(home.path + "/.config/.xash_id"))
        XCTAssertFalse(files.inspected.contains(home.path + "/.config/.xash_id"))
    }

    // MARK: Review round 2 — special library and executable bit (findings 6, 8)

    func testLibraryThatIsNotARegularFileMakesThePackageUnverifiable() {
        for entry in [FakeFileProbe.Entry.special, .directory] {
            let files = probe(engine: MachOFixture.installed, identity: MacIdentityFixture.zeroFile)
            files.set(app + "/Contents/MacOS/libxash.dylib", entry)
            let report = check(files)
            XCTAssertEqual(report.capabilityFailure, .unreadable)
            XCTAssertEqual(report.finding, .engineUnverifiable)
            XCTAssertEqual(report.action, .none)
            XCTAssertNotEqual(report.state, .unsupported)
        }
    }

    func testRealFIFOLibraryIsUnverifiable() throws {
        let temp = try TempDirectory()
        let appURL = temp.physicalURL.appendingPathComponent("Engine.app", isDirectory: true)
        let macOS = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try MachOFixture.writeExecutable(MachOFixture.thin(MachOFixture.installed), to: macOS.appendingPathComponent("xash3d"))
        XCTAssertEqual(mkfifo(macOS.appendingPathComponent("libxash.dylib").path, 0o644), 0)
        let probe = LocalFileProbe()
        XCTAssertEqual(probe.kind(macOS.appendingPathComponent("libxash.dylib")), .other)
        guard case .failure(let error) = EnginePaths.inspect(appURL, files: probe) else { return XCTFail("FIFO accepted") }
        XCTAssertEqual(error, .unreadable)
    }

    func testExecutableWithoutAnExecuteBitIsRejected() throws {
        let files = probe(identity: MacIdentityFixture.nonzeroFile)
        files.setPermissions(app + "/Contents/MacOS/xash3d", 0o644)
        XCTAssertEqual(check(files).capabilityFailure, .missingExecutable)
        XCTAssertEqual(EnginePaths.validateOverride(EnginePaths.defaultApp, files: files, forbiddenRoots: []),
                       .missingExecutable)
        files.setPermissions(app + "/Contents/MacOS/xash3d", 0o700)
        XCTAssertEqual(check(files).state, .supported)

        let temp = try TempDirectory()
        let appURL = temp.physicalURL.appendingPathComponent("Engine.app", isDirectory: true)
        let executable = appURL.appendingPathComponent("Contents/MacOS/xash3d")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MachOFixture.thin(MachOFixture.upstream).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        let probe = LocalFileProbe()
        XCTAssertEqual(probe.permissions(executable), 0o644)
        XCTAssertEqual(EnginePaths.validateOverride(appURL, files: probe, forbiddenRoots: []), .missingExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        XCTAssertNil(EnginePaths.validateOverride(appURL, files: probe, forbiddenRoots: []))
    }
}
