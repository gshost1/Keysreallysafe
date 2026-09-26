import Foundation

enum AppResources {
    static func applicationBundle(in bundle: Bundle = .main) -> Bundle? {
        if bundle.bundleURL.pathExtension == "app" { return bundle }
        // exec through a CLI symlink makes Bundle.main describe the symlink's directory.
        // Resolve only the actual executable's containing app, never an arbitrary ancestor.
        guard let executable = bundle.executableURL?.resolvingSymlinksInPath(),
              executable.lastPathComponent == "keys",
              executable.deletingLastPathComponent().lastPathComponent == "MacOS" else { return nil }
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let app = contents.deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        return Bundle(url: app)
    }

    static func root(in bundle: Bundle = .main) -> URL? {
        applicationBundle(in: bundle)?.resourceURL
    }
}
