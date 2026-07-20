@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation
import TextTargetHarnessCore

struct AXTargetProbe {
    func run(processIdentifier: Int32) -> TargetHarnessResult {
        let runID = "ax-\(processIdentifier)"
        let baselinePasteboard = NSPasteboard.general.changeCount
        guard AXIsProcessTrusted() else {
            return TargetHarnessResult(
                runId: runID,
                scenarioId: "target-native-textfield-direct",
                surface: "NSTextField",
                status: .tccRequired,
                outcome: "safeFallback",
                confirmedMutation: false,
                pasteboardChanged: false,
                assertions: [],
                residual: "Grant Accessibility permission to the built TextTargetHarness binary and rerun."
            )
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        guard let textField = waitForDescendant(
            of: application,
            accessibilityIdentifier: "harness.textField"
        ), let secureField = waitForDescendant(
            of: application,
            accessibilityIdentifier: "harness.secureField"
        ), let webEditable = waitForDescendant(
            of: application,
            domIdentifier: "web-editable"
        ) else {
            return failed(
                runID: runID,
                assertion: "targetDiscovery",
                detail: discoveryFailureDetail(application: application),
                pasteboardChanged: baselinePasteboard != NSPasteboard.general.changeCount
            )
        }

        _ = setAttribute(kAXFocusedAttribute as String, value: true as CFBoolean, on: textField)
        Thread.sleep(forTimeInterval: 0.08)
        var selectedRange = CFRange(location: 6, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &selectedRange),
              setAttribute(kAXSelectedTextRangeAttribute as String, value: rangeValue, on: textField),
              setAttribute(kAXSelectedTextAttribute as String, value: "Beta " as CFString, on: textField) else {
            return failed(
                runID: runID,
                assertion: "directAXWrite",
                detail: "AXSelectedText was not settable",
                pasteboardChanged: baselinePasteboard != NSPasteboard.general.changeCount
            )
        }

        Thread.sleep(forTimeInterval: 0.08)
        let value = copyStringAttribute(kAXValueAttribute as String, from: textField)
        let currentRange = copyRangeAttribute(kAXSelectedTextRangeAttribute as String, from: textField)
        let confirmed = value == "Alpha Beta Gamma"
            && currentRange?.location == 11
            && currentRange?.length == 0

        _ = setAttribute(kAXFocusedAttribute as String, value: true as CFBoolean, on: webEditable)
        Thread.sleep(forTimeInterval: 0.08)
        var webRange = CFRange(location: 10, length: 0)
        let webConfirmed: Bool
        if let webRangeValue = AXValueCreate(.cfRange, &webRange),
           setAttribute(
               kAXSelectedTextRangeAttribute as String,
               value: webRangeValue,
               on: webEditable
           ),
           postUnicodeText(" added") {
            Thread.sleep(forTimeInterval: 0.18)
            let webValue = copyStringAttribute(kAXValueAttribute as String, from: webEditable)
            let currentWebRange = copyRangeAttribute(
                kAXSelectedTextRangeAttribute as String,
                from: webEditable
            )
            webConfirmed = webValue == "Draft text added"
                && currentWebRange?.location == 16
                && currentWebRange?.length == 0
        } else {
            webConfirmed = false
        }

        let secureSubrole = copyStringAttribute(kAXSubroleAttribute as String, from: secureField)
        let secureProtected = copyBooleanAttribute(
            NSAccessibility.Attribute.containsProtectedContent.rawValue,
            from: secureField
        ) == true
        let secureRejected = secureSubrole == kAXSecureTextFieldSubrole as String || secureProtected
        let pasteboardChanged = baselinePasteboard != NSPasteboard.general.changeCount

        let assertions = [
            HarnessAssertion(
                id: "confirmedAXMutation",
                passed: confirmed,
                detail: confirmed ? "AXSelectedText mutation and range were confirmed" : "AX mutation could not be confirmed"
            ),
            HarnessAssertion(
                id: "confirmedWebUnicodeMutation",
                passed: webConfirmed,
                detail: webConfirmed ? "focused contenteditable accepted confirmed Unicode events" : "contenteditable Unicode mutation could not be confirmed"
            ),
            HarnessAssertion(
                id: "protectedTargetClassification",
                passed: secureRejected,
                detail: secureRejected ? "secure target classified without reading its value" : "secure target classification unavailable"
            ),
            HarnessAssertion(
                id: "generalPasteboardUnchanged",
                passed: !pasteboardChanged,
                detail: pasteboardChanged ? "general pasteboard changed during AX probe" : "general pasteboard changeCount stayed unchanged"
            )
        ]
        let passed = assertions.allSatisfy { $0.passed }
        return TargetHarnessResult(
            runId: runID,
            scenarioId: "target-native-textfield-direct",
            surface: "NSTextField+WKWebView.contenteditable+NSSecureTextField",
            status: passed ? .passed : .failed,
            outcome: confirmed ? "directAX" : "safeFallback",
            confirmedMutation: confirmed,
            pasteboardChanged: pasteboardChanged,
            assertions: assertions,
            residual: passed ? nil : "Inspect the assertion list; AX behavior varies by macOS and TCC state."
        )
    }

    private func waitForDescendant(
        of root: AXUIElement,
        accessibilityIdentifier: String
    ) -> AXUIElement? {
        // A cold AppKit/WebKit launch can announce application readiness before
        // the cross-process AX tree is published. Keep the probe bounded while
        // allowing the accessibility server to catch up on a freshly built app.
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let element = descendant(
                of: root,
                accessibilityIdentifier: accessibilityIdentifier
            ) {
                return element
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    private func waitForDescendant(
        of root: AXUIElement,
        domIdentifier: String
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let element = descendant(
                of: root,
                attribute: "AXDOMIdentifier",
                value: domIdentifier
            ) {
                return element
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    private func discoveryFailureDetail(application: AXUIElement) -> String {
        let windows = copyElementArrayAttribute(kAXWindowsAttribute as String, from: application).count
        let children = copyElementArrayAttribute(kAXChildrenAttribute as String, from: application).count
        let roleAvailable = copyStringAttribute(kAXRoleAttribute as String, from: application) != nil
        let roleState = roleAvailable ? "available" : "unavailable"
        return "Harness targets were not exposed through AX (windows=\(windows), children=\(children), applicationRole=\(roleState))"
    }

    private func failed(
        runID: String,
        assertion: String,
        detail: String,
        pasteboardChanged: Bool
    ) -> TargetHarnessResult {
        TargetHarnessResult(
            runId: runID,
            scenarioId: "target-native-textfield-direct",
            surface: "NSTextField",
            status: .failed,
            outcome: "safeFallback",
            confirmedMutation: false,
            pasteboardChanged: pasteboardChanged,
            assertions: [HarnessAssertion(id: assertion, passed: false, detail: detail)]
        )
    }

    private func descendant(
        of root: AXUIElement,
        accessibilityIdentifier: String
    ) -> AXUIElement? {
        descendant(
            of: root,
            attribute: kAXIdentifierAttribute as String,
            value: accessibilityIdentifier
        )
    }

    private func descendant(
        of root: AXUIElement,
        attribute: String,
        value: String
    ) -> AXUIElement? {
        var visited: [CFHashCode: [AXUIElement]] = [:]
        let windows = copyElementArrayAttribute(kAXWindowsAttribute as String, from: root)
        var queue: [AXUIElement] = windows.isEmpty ? [root] : windows
        var index = 0
        while index < queue.count, index < 10_000 {
            let element = queue[index]
            index += 1
            let hash = CFHash(element)
            let hashCollisionOrCycle = visited[hash, default: []].contains {
                CFEqual($0, element)
            }
            guard !hashCollisionOrCycle else { continue }
            visited[hash, default: []].append(element)
            if copyStringAttribute(attribute, from: element) == value {
                return element
            }
            queue.append(contentsOf: copyElementArrayAttribute(kAXChildrenAttribute as String, from: element))
        }
        return nil
    }

    private func postUnicodeText(_ text: String) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0,
                  keyDown: false
              ) else {
            return false
        }
        let utf16 = Array(text.utf16)
        guard utf16.withUnsafeBufferPointer({ buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
            return true
        }) else {
            return false
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func copyElementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let values = value as? [AXUIElement] else {
            return []
        }
        return values
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyBooleanAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func copyRangeAttribute(_ attribute: String, from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func setAttribute(_ attribute: String, value: CFTypeRef, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }
}
