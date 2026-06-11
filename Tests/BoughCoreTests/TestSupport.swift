import Foundation

// Thread-safe counter for tracking call counts in tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

// Thread-safe mutable box for capturing state in @Sendable closures.
// Supports both property-style access (.value) and method-style (.get()/.set()).
final class MutableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }

    func get() -> T {
        lock.lock(); defer { lock.unlock() }; return _value
    }

    func set(_ newValue: T) {
        lock.lock(); _value = newValue; lock.unlock()
    }
}
