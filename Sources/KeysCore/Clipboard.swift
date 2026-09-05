import AppKit
import Foundation

enum ClipboardWipe {
    static let seconds: TimeInterval = 20
}

protocol ClipboardClient: Sendable {
    func copy(_ value: String)
    func copyAndHoldUntilWipe(_ value: String)
    func copyAndWipeInBackground(_ value: String)
}

final class FakeClipboard: ClipboardClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value: String?
    private(set) var lastBackgroundWipe: TimeInterval?

    func copy(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func copyAndHoldUntilWipe(_ value: String) {
        copy(value)
    }

    func copyAndWipeInBackground(_ value: String) {
        copy(value)
        lock.lock()
        lastBackgroundWipe = ClipboardWipe.seconds
        lock.unlock()
    }

    func wipe() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

struct AppKitClipboard: ClipboardClient {
    func copy(_ value: String) {
        runOnMain {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(value, forType: .string)
        }
    }

    func copyAndHoldUntilWipe(_ value: String) {
        copy(value)
        Thread.sleep(forTimeInterval: ClipboardWipe.seconds)
        wipeIfStill(value)
    }

    func copyAndWipeInBackground(_ value: String) {
        copy(value)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ClipboardWipe.seconds) {
            self.wipeIfStill(value)
        }
    }

    func wipeIfStill(_ value: String) {
        runOnMain {
            let pb = NSPasteboard.general
            if pb.string(forType: .string) == value {
                pb.clearContents()
            }
        }
    }

    static func readFromPasteboard() throws -> String {
        var result: String?
        runOnMain {
            result = NSPasteboard.general.string(forType: .string)
        }
        guard let value = result, !value.isEmpty else {
            throw AppError.usage("clipboard is empty")
        }
        return value
    }
}

func runOnMain(_ body: () -> Void) {
    if Thread.isMainThread {
        body()
    } else {
        DispatchQueue.main.sync(execute: body)
    }
}

func onMain<T>(_ body: () throws -> T) throws -> T {
    if Thread.isMainThread {
        return try body()
    }
    return try DispatchQueue.main.sync(execute: body)
}

func runOnMainActor(_ body: @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }
}
