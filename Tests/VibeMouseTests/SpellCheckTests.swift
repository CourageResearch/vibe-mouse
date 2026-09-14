import XCTest
import AppKit
import ApplicationServices
import Carbon.HIToolbox
@testable import VibeMouse

final class SpellCheckInputTests: XCTestCase {
    func testLostKeyReleaseDoesNotDisableFutureTaps() {
        var input = SpellCheckInput()
        _ = input.handle(type: .keyDown, code: Int64(kVK_ANSI_C), flags: [], time: 0, enabled: true)
        // An earlier tap consumed C-up. Hardware reports that C is released.
        input.reconcileHeldInputs(isKeyDown: { _ in false }, isButtonDown: { _ in false })
        _ = input.handle(type: .flagsChanged, code: Int64(kVK_Option), flags: .maskAlternate, time: 1, enabled: true)
        XCTAssertTrue(input.handle(type: .flagsChanged, code: Int64(kVK_Option), flags: [], time: 1.1, enabled: true))
    }

    func testPhysicalKeyAndMouseHoldsStillPreventTapsAfterReconciliation() {
        for type in [CGEventType.keyDown, .leftMouseDown] {
            var input = SpellCheckInput()
            _ = input.handle(type: type, code: Int64(kVK_ANSI_C), flags: [], time: 0, enabled: true)
            input.reconcileHeldInputs(isKeyDown: { _ in true }, isButtonDown: { _ in true })
            _ = input.handle(type: .flagsChanged, code: Int64(kVK_Option), flags: .maskAlternate, time: 1, enabled: true)
            XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(kVK_Option), flags: [], time: 1.1, enabled: true))
        }
    }

    func testTapEitherSideOfEitherModifierAndLongHold() {
        for (code, flag) in [(kVK_Command, CGEventFlags.maskCommand), (kVK_RightCommand, .maskCommand),
                             (kVK_Option, .maskAlternate), (kVK_RightOption, .maskAlternate)] {
            var input = SpellCheckInput()
            XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(code), flags: flag, time: 1, enabled: true))
            XCTAssertTrue(input.handle(type: .flagsChanged, code: Int64(code), flags: [], time: 1.2, enabled: true))
            XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(code), flags: flag, time: 2, enabled: true))
            XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(code), flags: [], time: 3, enabled: true))
        }
    }

    func testKeysClicksScrollAndOtherModifiersCancelTap() {
        for type in [CGEventType.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                     .leftMouseDragged, .scrollWheel, .flagsChanged, CGEventType(rawValue: 14)!] {
            var input = SpellCheckInput()
            _ = input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: .maskCommand, time: 1, enabled: true)
            _ = input.handle(type: type, code: Int64(kVK_Shift), flags: [.maskCommand, .maskShift], time: 1.1, enabled: true)
            XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: [], time: 1.2, enabled: true), "\(type)")
        }
    }

    func testAlreadyHeldKeysOrMouseButtonsDoNotStartATap() {
        for type in [CGEventType.keyDown, .leftMouseDown, .rightMouseDown] {
            var input = SpellCheckInput()
            _ = input.handle(type: type, code: Int64(kVK_ANSI_C), flags: [], time: 1, enabled: true)
            _ = input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: .maskCommand, time: 1.1, enabled: true)
            XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: [], time: 1.2, enabled: true))
        }
    }

    func testResetDisableUnpairedReleaseAndTwoCommandKeys() {
        var input = SpellCheckInput()
        XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: [], time: 0, enabled: true))
        _ = input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: .maskCommand, time: 1, enabled: true)
        input.reset()
        XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: [], time: 1.1, enabled: true))
        _ = input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: .maskCommand, time: 2, enabled: true)
        XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: [], time: 2.1, enabled: false))
        _ = input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: .maskCommand, time: 3, enabled: true)
        _ = input.handle(type: .flagsChanged, code: Int64(kVK_RightCommand), flags: .maskCommand, time: 3.1, enabled: true)
        XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(kVK_Command), flags: .maskCommand, time: 3.2, enabled: true))
        XCTAssertFalse(input.handle(type: .flagsChanged, code: Int64(kVK_RightCommand), flags: [], time: 3.3, enabled: true))
    }
}

final class SpellingWordTests: XCTestCase {
    func testCaretInsideAndAfterWordWithEmojiAndPunctuation() {
        let text = "🙂 fasinating, okay"
        for location in [3, 6, 13] {
            let word = SpellingWord.atSelection(NSRange(location: location, length: 0), in: text)
            XCTAssertEqual(word?.text, "fasinating")
            XCTAssertEqual(word?.range, NSRange(location: 3, length: 10))
        }
        XCTAssertNil(SpellingWord.atSelection(NSRange(location: 14, length: 0), in: text))
    }

    func testWordSelectionAndInvalidOrMultipleWordSelection() {
        XCTAssertEqual(SpellingWord.atSelection(NSRange(location: 0, length: 5), in: "heloo world")?.text, "heloo")
        for range in [NSRange(location: 0, length: 11), NSRange(location: NSNotFound, length: 0),
                      NSRange(location: 50, length: 0), NSRange(location: 2, length: Int.max)] {
            XCTAssertNil(SpellingWord.atSelection(range, in: "heloo world"))
        }
        XCTAssertNil(SpellingWord.atSelection(NSRange(location: 0, length: 0), in: ""))
    }
}

@MainActor
private final class FakeSpellingAccess: SpellingAccess {
    var target: SpellingTarget? = SpellingTarget(element: AXUIElementCreateApplication(42),
        processIdentifier: 42, value: "fasinating", selection: NSRange(location: 5, length: 0))
    var rect: CGRect? = CGRect(x: 120, y: 240, width: 10, height: 20)
    var focused = true
    var clicked: [CGPoint] = []
    var requestedRange: NSRange?
    var pointer: SpellingPointerTarget?
    var pointerUnchanged = true
    func focusedTarget() -> SpellingTarget? { target }
    func bounds(for range: NSRange, in target: SpellingTarget) -> CGRect? { requestedRange = range; return rect }
    func stillFocused(_ target: SpellingTarget, at point: CGPoint) -> Bool { focused }
    func showContextMenu(at point: CGPoint) -> Bool { clicked.append(point); return true }
    func pointerTarget() -> SpellingPointerTarget? { pointer }
    func stillUnderPointer(_ target: SpellingPointerTarget) -> Bool { pointerUnchanged }
}

@MainActor
final class SpellCheckServiceTests: XCTestCase {
    func testSystemEnglishCheckerRecognizesScreenshotTypo() {
        let range = NSSpellChecker.shared.checkSpelling(of: "fasinating", startingAt: 0,
            language: "en_US", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        XCTAssertEqual(range, NSRange(location: 0, length: 10))
    }

    func testMisspelledWordUsesCharacterBoundsAtCaret() {
        let access = FakeSpellingAccess()
        let service = SpellCheckService(access: access, isMisspelled: { $0 == "fasinating" })
        XCTAssertNotNil(service.showSuggestions())
        XCTAssertEqual(access.requestedRange, NSRange(location: 5, length: 1))
        XCTAssertEqual(access.clicked, [CGPoint(x: 125, y: 250)])
    }

    func testCorrectTextUnsupportedBoundsAndStaleFocusNeverClick() {
        let access = FakeSpellingAccess()
        _ = SpellCheckService(access: access, isMisspelled: { _ in false }).showSuggestions()
        let service = SpellCheckService(access: access, isMisspelled: { _ in true })
        for rect in [nil, CGRect.zero, CGRect.null, CGRect.infinite] {
            access.rect = rect
            _ = service.showSuggestions()
        }
        access.rect = CGRect(x: 120, y: 240, width: 10, height: 20)
        access.focused = false
        XCTAssertNil(service.showSuggestions())
        access.target = nil
        _ = service.showSuggestions()
        XCTAssertTrue(access.clicked.isEmpty)
    }

    func testEditorsWithoutTextRangesCanUseThePointer() {
        let access = FakeSpellingAccess()
        let point = CGPoint(x: 400, y: 500)
        access.pointer = SpellingPointerTarget(element: AXUIElementCreateApplication(42), processIdentifier: 42, point: point)
        access.target = nil
        XCTAssertNotNil(SpellCheckService(access: access).showSuggestions())
        XCTAssertEqual(access.clicked, [point])
    }

    func testNativeDictionaryAndMissingCharacterBoundsCanUsePointer() {
        for misspelled in [false, true] {
            let access = FakeSpellingAccess()
            let point = CGPoint(x: 400, y: 500)
            access.pointer = SpellingPointerTarget(element: AXUIElementCreateApplication(42), processIdentifier: 42, point: point)
            access.rect = nil
            _ = SpellCheckService(access: access, isMisspelled: { _ in misspelled }).showSuggestions()
            XCTAssertEqual(access.clicked, [point])
        }
    }

    func testPointerMovingOrFocusChangingNeverRedirectsACorrection() {
        let access = FakeSpellingAccess()
        access.pointer = SpellingPointerTarget(element: AXUIElementCreateApplication(42), processIdentifier: 42,
                                               point: CGPoint(x: 400, y: 500))
        access.pointerUnchanged = false
        _ = SpellCheckService(access: access, isMisspelled: { _ in false }).showSuggestions()
        access.pointerUnchanged = true
        access.focused = false
        _ = SpellCheckService(access: access, isMisspelled: { _ in true }).showSuggestions()
        XCTAssertTrue(access.clicked.isEmpty)
    }
}
