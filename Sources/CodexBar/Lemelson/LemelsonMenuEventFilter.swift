import AppKit
import ObjectiveC

/// Sees every event the menu tracking loop pulls from the queue, before NSMenu acts on it.
///
/// The author's shortcut monitor peeks the queue from a run-loop observer. That observer only runs
/// between run-loop passes, and a key event that arrives while the loop sleeps is usually read by
/// NSMenu in the same pass, before any observer runs. Such a key then never reaches CodexBar, and
/// AppKit's own handling of left/right in a status item menu moves on to the neighbouring menu bar
/// item. This filter sits on `-[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:]`,
/// the call the tracking loop uses, so it sees each event exactly once, at dequeue time.
@MainActor
enum LemelsonMenuEventFilter {
    /// Returns true to swallow the event. Called only for events dequeued in event-tracking mode.
    static var handler: (@MainActor (NSEvent) -> Bool)?
    /// Returns a replacement for a dequeued event, in any mode. The detail panel uses it while a control
    /// inside it tracks the mouse in a loop of its own: that loop reads the events through this same
    /// call, and they must be addressed to the panel window wherever the pointer is.
    static var rewrite: (@MainActor (NSEvent) -> NSEvent?)?
    #if DEBUG
    /// Every event dequeued in any mode, before `handler`. Used by the self-test probe.
    static var probe: (@MainActor (NSEvent, String, Bool) -> Void)?
    #endif

    private static var installed = false

    static func installIfNeeded() {
        guard !self.installed else { return }
        self.installed = true
        let selector = #selector(NSApplication.nextEvent(matching:until:inMode:dequeue:))
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        typealias Original = @convention(c) (
            NSApplication, Selector, UInt64, NSDate?, NSString, ObjCBool) -> NSEvent?
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let trackingMode = RunLoop.Mode.eventTracking.rawValue
        let replacement: @convention(block) (NSApplication, UInt64, NSDate?, NSString, ObjCBool) -> NSEvent? = {
            app, mask, expiration, mode, dequeue in
            while true {
                guard let dequeued = original(app, selector, mask, expiration, mode, dequeue) else { return nil }
                // Runs on the main thread (this is the main thread's event loop); NSEvent is not Sendable.
                nonisolated(unsafe) var event = dequeued
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    if dequeue.boolValue, let replacement = Self.rewrite?(event) {
                        event = replacement
                    }
                    #if DEBUG
                    Self.probe?(event, mode as String, dequeue.boolValue)
                    #endif
                    guard dequeue.boolValue, (mode as String) == trackingMode, let handler = Self.handler else {
                        return false
                    }
                    return handler(event)
                }
                // A swallowed event is gone from the queue; wait for the next one within the same
                // deadline (an expired deadline makes the original return nil or a queued event).
                if !swallow { return event }
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
