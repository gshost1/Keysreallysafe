import Foundation

/// Seeds the status item's saved placement so a first launch on a full notched menu bar
/// does not drop the item. AppKit reads `NSStatusItem Preferred Position <autosaveName>`
/// (a point distance from the right edge) when the autosave name is applied; with no saved
/// value it places the item far left, the first spot that is dropped when the bar is full.
/// This is an inferred mitigation, not an observed fix — see docs/menubar-recovery.md.
/// The two defaults calls the seed needs, so tests can use memory instead of a real
/// preferences domain (cfprefsd leaves an empty plist behind for every throwaway suite).
protocol MenubarDefaults: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: MenubarDefaults {}

enum MenubarPosition {
    enum Decision: Equatable { case seeded(Double), keptExisting(Double), skippedHidden }

    static let autosaveName = "Keysreallysafe.usage"
    static let preferredDistanceFromRightEdge: Double = 200   // a guess, see docs

    static func positionKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }
    static func visibleKey(_ name: String) -> String { "NSStatusItem Visible \(name)" }

    /// Writes `preferred` only when no position is saved and the user has not hidden the
    /// item; never overwrites a user's position or a hidden item.
    static func seedIfUnset(defaults: MenubarDefaults, autosaveName: String, preferred: Double) -> Decision {
        if let visible = defaults.object(forKey: visibleKey(autosaveName)) as? Bool, visible == false {
            return .skippedHidden
        }
        if let existing = defaults.object(forKey: positionKey(autosaveName)) as? Double {
            return .keptExisting(existing)
        }
        defaults.set(preferred, forKey: positionKey(autosaveName))
        return .seeded(preferred)
    }
}
