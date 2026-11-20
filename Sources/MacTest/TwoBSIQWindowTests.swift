#if os(macOS)
import AppKit
import XCTest
@testable import MorseRunnerCore
@testable import MorseRunner

@MainActor
final class TwoBSIQWindowTests: XCTestCase {
    func testSettingsMenuReturnsToTheStandardWindow() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let mainMenu = NSMenu()
        mainMenu.addItem(withTitle: "App", action: nil, keyEquivalent: "")
        mainMenu.addItem(withTitle: "Window", action: nil, keyEquivalent: "")
        NSApp.mainMenu = mainMenu

        let main = MainWindowController()
        let mainWindow = try XCTUnwrap(main.window)
        main.showWindow(nil)
        defer { mainWindow.close() }
        let settings = try XCTUnwrap(mainMenu.items.compactMap(\.submenu).first { $0.title == "Settings" })
        let launch = try XCTUnwrap(settings.items.first { $0.title.contains("2BSIQ") })
        let activity = try XCTUnwrap(settings.item(withTitle: "Activity"))
        let views = descendants(try XCTUnwrap(mainWindow.contentView))
        let sliders = views.compactMap { $0 as? NSSlider }
        XCTAssertEqual(sliders.count, 2)
        let sliderValues = sliders.map(\.doubleValue)
        let contest = Settings.simContest

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(launch.action), to: launch.target, from: launch))
        let training = try XCTUnwrap(NSApp.windows.first { $0.title == "2BSIQ — CQ WW CW" && $0.isVisible })
        XCTAssertFalse(mainWindow.isVisible)
        XCTAssertTrue(activity.isHidden)
        training.close()
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertFalse(activity.isHidden)
        XCTAssertEqual(sliders.map(\.doubleValue), sliderValues)
        XCTAssertEqual(Settings.simContest, contest)
    }

    func testVFOFieldsPreviewAndTrackActualTransmission() throws {
        _ = NSApplication.shared
        let previousAudio = ProcessInfo.processInfo.environment["MORSE_RUNNER_NO_AUDIO"]
        setenv("MORSE_RUNNER_NO_AUDIO", "1", 1)
        defer {
            if let previousAudio {
                setenv("MORSE_RUNNER_NO_AUDIO", previousAudio, 1)
            } else {
                unsetenv("MORSE_RUNNER_NO_AUDIO")
            }
        }
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = TwoBSIQWindowController(
            call: "BH5HIE", wpm: 85, pitch: 600, volume: 0.2, defaults: defaults,
            catalog: TwoBSIQCatalog(history: "JA1ABC,25,\n")
        )
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let views = descendants(try XCTUnwrap(window.contentView))
        let a = try XCTUnwrap(views.compactMap { $0 as? TwoBSIQEntryView }.first)
        let b = try XCTUnwrap(views.compactMap { $0 as? TwoBSIQEntryView }.last)
        let aFrame = a.convert(a.bounds, to: nil)
        let bFrame = b.convert(b.bounds, to: nil)
        XCTAssertEqual(aFrame.minX, 16, accuracy: 1)
        XCTAssertLessThan(aFrame.maxX, bFrame.minX)
        XCTAssertEqual(aFrame.width, bFrame.width, accuracy: 1)
        XCTAssertEqual(bFrame.maxX, try XCTUnwrap(window.contentView).bounds.maxX - 16, accuracy: 1)
        let start = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Start" })
        start.performClick(nil)
        XCTAssertNotNil(a.field.currentEditor())
        try key("\r", 36, in: window)
        XCTAssertTrue(a.field.isHidden)
        XCTAssertTrue(visibleText(in: a).contains("CQ TEST BH5HIE"))

        try key("\\", 42, in: window)
        XCTAssertNotNil(b.field.currentEditor())
        try key("x", 7, in: window)
        XCTAssertTrue(visibleText(in: b).contains(" ENN 24"))
        try key("\\", 42, in: window)
        XCTAssertTrue(a.selected)
        XCTAssertEqual(b.call, "X")

        XCTAssertTrue(waitUntil { !a.field.isHidden })
        XCTAssertTrue(waitUntil {
            views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Send exchange" }
        })
        XCTAssertNotNil(a.field.currentEditor())
        for (character, code): (String, UInt16) in [("j", 38), ("a", 0), ("1", 18), ("a", 0), ("b", 11), ("c", 8)] {
            try key(character, code, in: window)
        }
        XCTAssertEqual(a.call, "JA1ABC")
        XCTAssertTrue(visibleText(in: a).contains(" ENN 24"))
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "CQ Zone 25" })
        try key("\r", 36, in: window)
        XCTAssertTrue(visibleText(in: a).contains("JA1ABC ENN 24"))
        XCTAssertTrue(waitUntil { visibleText(in: a).contains("A1ABC ENN 24") })
        try key("\\", 42, in: window)
        XCTAssertNotNil(b.field.currentEditor())
        XCTAssertEqual(b.call, "X")
        XCTAssertTrue(waitUntil { !a.field.isHidden })
        XCTAssertEqual(a.call, "")
        XCTAssertFalse(visibleText(in: a).contains(" ENN 24"))

        XCTAssertTrue(waitUntil {
            views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Send TU" }
        })
        try key("\\", 42, in: window)
        try key("\r", 36, in: window)
        XCTAssertTrue(visibleText(in: a).contains("TU BH5HIE"))
        let log = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        XCTAssertTrue(waitUntil { log.numberOfRows == 1 })
        XCTAssertEqual(b.call, "X")
    }

    func testStereoAndManualZoneRestoreInNewWindow() throws {
        _ = NSApplication.shared
        let (name, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let catalog = TwoBSIQCatalog(history: "JA1ABC,25,\n")
        let first = TwoBSIQWindowController(call: "W1ZZZ", wpm: 25, pitch: 600,
                                           volume: 0.2, defaults: defaults, catalog: catalog)
        let firstWindow = try XCTUnwrap(first.window)
        let firstViews = descendants(try XCTUnwrap(firstWindow.contentView))
        let slider = try XCTUnwrap(firstViews.compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.doubleValue, 1)
        slider.doubleValue = 0.5
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        let zone = try XCTUnwrap(firstViews.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(zone.selectedTag(), 0)
        zone.selectItem(withTag: 5)
        XCTAssertTrue(zone.sendAction(zone.action, to: zone.target))
        firstWindow.close()

        let restored = TwoBSIQWindowController(call: "w1zzz", wpm: 25, pitch: 600,
                                              volume: 0.2, defaults: defaults, catalog: catalog)
        let restoredWindow = try XCTUnwrap(restored.window)
        defer { restoredWindow.close() }
        let restoredViews = descendants(try XCTUnwrap(restoredWindow.contentView))
        XCTAssertEqual(restoredViews.compactMap { $0 as? NSSlider }.first?.doubleValue, 0.5)
        XCTAssertEqual(restoredViews.compactMap { $0 as? NSPopUpButton }.first?.selectedTag(), 5)
    }

    private func makeDefaults() throws -> (String, UserDefaults) {
        let name = "TwoBSIQWindowTests." + UUID().uuidString
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func visibleText(in entry: TwoBSIQEntryView) -> [String] {
        entry.subviews.compactMap { view in
            guard let field = view as? NSTextField, !field.isHidden else { return nil }
            return field.stringValue
        }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.006))
        }
        return condition()
    }

    private func key(_ characters: String, _ code: UInt16, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
        NSApp.sendEvent(event)
    }
}
#endif
