@preconcurrency import Carbon
import Foundation

enum PushToTalkHotKeyEvent: Equatable, Sendable {
    case pressed
    case released
}

struct PushToTalkHotKeyConfiguration: Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let defaultLocal = Self(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey | optionKey)
    )
}

struct PushToTalkEventReducer: Sendable {
    private(set) var isPressed = false

    mutating func consume(_ event: PushToTalkHotKeyEvent) -> PushToTalkHotKeyEvent? {
        switch event {
        case .pressed where !isPressed:
            isPressed = true
            return .pressed
        case .released where isPressed:
            isPressed = false
            return .released
        case .pressed, .released:
            return nil
        }
    }
}

enum GlobalHotKeyError: Error, Equatable, Sendable {
    case handlerRegistrationFailed(OSStatus)
    case hotKeyRegistrationFailed(OSStatus)

    var status: OSStatus {
        switch self {
        case .handlerRegistrationFailed(let status), .hotKeyRegistrationFailed(let status):
            status
        }
    }
}

@MainActor
protocol PushToTalkHotKeyControlling: AnyObject {
    func register(
        configuration: PushToTalkHotKeyConfiguration,
        handler: @escaping @MainActor @Sendable (PushToTalkHotKeyEvent) -> Void
    ) throws
    func unregister()
}

@MainActor
final class CarbonPushToTalkHotKeyController: PushToTalkHotKeyControlling {
    private static let signature: OSType = 0x464C5354 // FLST
    private static let identifier: UInt32 = 1

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var sinkPointer: UnsafeMutableRawPointer?

    func register(
        configuration: PushToTalkHotKeyConfiguration,
        handler: @escaping @MainActor @Sendable (PushToTalkHotKeyEvent) -> Void
    ) throws {
        unregister()

        let sink = CarbonHotKeySink(
            signature: Self.signature,
            identifier: Self.identifier,
            handler: handler
        )
        let pointer = Unmanaged.passRetained(sink).toOpaque()
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        var installedHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonPushToTalkEventHandler,
            eventTypes.count,
            &eventTypes,
            pointer,
            &installedHandler
        )
        guard installStatus == noErr else {
            Unmanaged<CarbonHotKeySink>.fromOpaque(pointer).release()
            throw GlobalHotKeyError.handlerRegistrationFailed(installStatus)
        }

        var registeredHotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: Self.identifier
        )
        let registerStatus = RegisterEventHotKey(
            configuration.keyCode,
            configuration.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registerStatus == noErr else {
            if let installedHandler { RemoveEventHandler(installedHandler) }
            Unmanaged<CarbonHotKeySink>.fromOpaque(pointer).release()
            throw GlobalHotKeyError.hotKeyRegistrationFailed(registerStatus)
        }

        eventHandler = installedHandler
        hotKey = registeredHotKey
        sinkPointer = pointer
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let sinkPointer {
            Unmanaged<CarbonHotKeySink>.fromOpaque(sinkPointer).release()
        }
        hotKey = nil
        eventHandler = nil
        sinkPointer = nil
    }

}

private final class CarbonHotKeySink: @unchecked Sendable {
    let signature: OSType
    let identifier: UInt32

    private let lock = NSLock()
    private var reducer = PushToTalkEventReducer()
    private let handler: @MainActor @Sendable (PushToTalkHotKeyEvent) -> Void

    init(
        signature: OSType,
        identifier: UInt32,
        handler: @escaping @MainActor @Sendable (PushToTalkHotKeyEvent) -> Void
    ) {
        self.signature = signature
        self.identifier = identifier
        self.handler = handler
    }

    func receive(_ event: PushToTalkHotKeyEvent) {
        let accepted = lock.withLock { reducer.consume(event) }
        guard let accepted else { return }
        Task { @MainActor [handler] in handler(accepted) }
    }
}

private let carbonPushToTalkEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let sink = Unmanaged<CarbonHotKeySink>.fromOpaque(userData).takeUnretainedValue()

    var identifier = EventHotKeyID()
    let parameterStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard parameterStatus == noErr,
          identifier.signature == sink.signature,
          identifier.id == sink.identifier else {
        return OSStatus(eventNotHandledErr)
    }

    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed):
        sink.receive(.pressed)
        return noErr
    case UInt32(kEventHotKeyReleased):
        sink.receive(.released)
        return noErr
    default:
        return OSStatus(eventNotHandledErr)
    }
}
