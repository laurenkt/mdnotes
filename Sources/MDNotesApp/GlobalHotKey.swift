import AppKit
import Carbon.HIToolbox

/// One system-wide key combination, registered through Carbon `RegisterEventHotKey` (W-3).
/// No Accessibility permission is needed: the window server delivers the press to the
/// process that registered the combination, whichever application is active.
///
/// Each instance holds at most one registration; `register(_:)` replaces it and
/// `unregister()` releases it, as does deallocation, so a registration never outlives its
/// owner. A press reaches `onPress` on the main thread. `fire()` runs the same path by hand,
/// for tests, since a press cannot be synthesised without posting events system-wide.
///
/// Carbon delivers presses to one handler installed once per process on the application
/// event target; it looks the instance up by the id the registration carried, so an instance
/// that has been unregistered, or freed, is never called.
@MainActor
public final class GlobalHotKey {
    /// A Carbon call declined. `eventHotKeyExistsErr` (-9878) means this process already has
    /// the combination registered.
    public struct RegistrationError: Error, Equatable {
        public let status: OSStatus

        public init(status: OSStatus) { self.status = status }
    }

    /// The combination registered, or nil when none is.
    public private(set) var hotKey: HotKey?
    /// Called on the main thread when the combination is pressed.
    public var onPress: (@MainActor () -> Void)?

    public var isRegistered: Bool { hotKey != nil }

    private let id: UInt32
    /// The Carbon reference as a bit pattern, zero when none: a `UInt` is Sendable, so the
    /// nonisolated `deinit` may read it, where an `EventHotKeyRef` it could not.
    private var referenceBits: UInt = 0

    /// The instances with a live registration, by id. Weak, so a freed instance is not kept.
    private static var registered: [UInt32: WeakReference] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?
    /// `MDNT`: the signature every registration of this process carries.
    private static let signature: OSType = 0x4D44_4E54

    public init() {
        id = Self.nextID
        Self.nextID += 1
    }

    /// Releases the Carbon registration with the instance. Not isolated: the table entry is
    /// weak and so already empty, and the dispatch tolerates it, so only Carbon needs telling.
    deinit {
        if let reference = EventHotKeyRef(bitPattern: referenceBits) { UnregisterEventHotKey(reference) }
    }

    /// Registers `hotKey` system-wide, releasing whatever this instance had registered first.
    /// If Carbon declines, the previous combination is put back and the error thrown, so a
    /// failed change costs nothing.
    public func register(_ hotKey: HotKey) throws {
        let previous = self.hotKey
        unregister()
        do {
            try registerWithCarbon(hotKey)
        } catch {
            if let previous { try? registerWithCarbon(previous) }
            throw error
        }
    }

    /// Releases the registration, if any. Pressing the combination then reaches whichever
    /// application registers it next, or nobody.
    public func unregister() {
        guard let reference = EventHotKeyRef(bitPattern: referenceBits) else { return }
        UnregisterEventHotKey(reference)
        referenceBits = 0
        hotKey = nil
        Self.registered[id] = nil
        // Entries of instances freed without unregistering are empty; drop them.
        Self.registered = Self.registered.filter { $0.value.instance != nil }
    }

    /// What a press does: calls `onPress`. Tests drive the hotkey through this.
    public func fire() {
        onPress?()
    }

    private func registerWithCarbon(_ hotKey: HotKey) throws {
        try Self.installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotKey.keyCode), hotKey.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { throw RegistrationError(status: status) }
        referenceBits = UInt(bitPattern: reference)
        self.hotKey = hotKey
        Self.registered[id] = WeakReference(self)
    }

    private static func installHandlerIfNeeded() throws {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return status }
                // Carbon dispatches application-target events from the main run loop.
                MainActor.assumeIsolated { GlobalHotKey.registered[hotKeyID.id]?.instance?.fire() }
                return noErr
            }, 1, &spec, nil, &installed)
        guard status == noErr else { throw RegistrationError(status: status) }
        handler = installed
    }

    private final class WeakReference {
        weak var instance: GlobalHotKey?
        init(_ instance: GlobalHotKey) { self.instance = instance }
    }
}
