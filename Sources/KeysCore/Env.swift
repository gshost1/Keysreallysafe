import Darwin
import Foundation

enum EnvVar {
    static func canonicalize(_ name: String) -> String {
        var s = name.trimmingCharacters(
            in: .whitespacesAndNewlines
                .union(.controlCharacters)
                .union(CharacterSet(charactersIn: "\u{00A0}\u{200B}\u{200C}\u{200D}\u{FEFF}\u{202F}\u{2060}"))
        )
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("`", "`"),
            ("“", "”"), ("‘", "’"),
        ]
        while s.count >= 2, let first = s.first, let last = s.last,
              pairs.contains(where: { $0.0 == first && $0.1 == last })
        {
            s.removeFirst()
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    static func validate(_ name: String) throws {
        let trimmed = canonicalize(name)
        if trimmed.isEmpty {
            throw AppError.usage("environment variable name is missing (example: OPENAI_API_KEY)")
        }
        if trimmed.hasPrefix("$") {
            let bare = String(trimmed.drop(while: { $0 == "$" }))
            throw AppError.usage("use \(bare) not \(trimmed) — no dollar sign")
        }
        guard trimmed.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_]*$/) != nil else {
            throw AppError.usage(
                "invalid environment variable \(trimmed.debugDescription) (letters, digits, underscore only, e.g. OPENAI_API_KEY)"
            )
        }
    }
}

/// How a launched command ended.
enum ChildExit: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    init(waitStatus: Int32) {
        let signal = waitStatus & 0x7f
        self = signal == 0 ? .exited((waitStatus >> 8) & 0xff) : .signaled(signal)
    }

    /// What a shell shows in `$?` for it.
    var status: Int32 {
        switch self {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
    }

    /// Ends keys the way the command ended. Dying of the same signal matters: a shell script
    /// looping over `keys env` stops on Ctrl-C only when the job was killed by SIGINT, and goes
    /// on to the next round when it merely exited 130. Signals that leave a core or a crash
    /// report become 128 + n instead, so keys is not reported as the crash.
    func exitProcess() -> Never {
        if case .signaled(let sig) = self, Self.reraised.contains(sig) {
            fflush(nil)
            signal(sig, SIG_DFL)
            var unblock = sigset_t()
            sigemptyset(&unblock)
            sigaddset(&unblock, sig)
            pthread_sigmask(SIG_UNBLOCK, &unblock, nil)
            raise(sig)
        }
        Darwin.exit(status)
    }

    static let reraised: Set<Int32> = [SIGHUP, SIGINT, SIGKILL, SIGPIPE, SIGALRM, SIGTERM, SIGUSR1, SIGUSR2]
}

protocol CommandRunner: Sendable {
    func run(argv: [String], extraEnv: [String: String]) throws -> ChildExit
}

/// Runs the command as a child in keys' own process group. Foundation's `Process` gave it a
/// group of its own, outside the terminal's foreground group: Ctrl-C ended keys and left the
/// command running detached (and `keys agent` never revoked its grant), and a command that
/// set up the terminal, as every coding agent does, was stopped by SIGTTOU.
struct SpawnCommandRunner: CommandRunner {
    /// The CLI exits right after the command, and what it does in between (keys agent's revoke)
    /// must not be cut short by a second Ctrl-C or by the SIGHUP a closing terminal sends after
    /// the first, so by default the handlers stay, passing nothing on, until keys exits.
    /// Tests put the old ones back.
    var restoresHandlers = false

    func run(argv: [String], extraEnv: [String: String]) throws -> ChildExit {
        guard !argv.isEmpty else { throw AppError.usage("missing command after --") }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extraEnv {
            env[key] = value
        }
        // /usr/bin/env finds the command on the child's PATH, as Process did.
        var arguments = (["/usr/bin/env"] + argv).map { strdup($0) }
        arguments.append(nil)
        var environment = env.map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }

        // Only the terminal's three descriptors reach the command, as with Process; the catalog
        // and the control socket stay in keys. Looked at before `install` opens /dev/tty, which
        // could take the number of a closed one.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where fcntl(fd, F_GETFD) != -1 {
            posix_spawn_file_actions_addinherit_np(&actions, fd)
        }

        // Held back on this thread from before the handler goes in until it knows the child, so
        // a signal in between is passed on rather than dropped. Dispatch's worker threads never
        // take signals.
        var held = ChildSignals.caughtSet, previousMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &held, &previousMask)
        let replaced = ChildSignals.install()
        defer { if restoresHandlers { ChildSignals.restore(replaced) } }
        var attributes = ChildSignals.spawnAttributes(keptIgnored: ChildSignals.caught.filter { sig in
            !replaced.contains { $0.signal == sig }
        })
        defer { posix_spawnattr_destroy(&attributes) }

        var pid: pid_t = 0
        let spawned = arguments.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, args.baseAddress!, envp.baseAddress!)
            }
        }
        if spawned == 0 { ChildSignals.target = pid }
        pthread_sigmask(SIG_SETMASK, &previousMask, nil)
        guard spawned == 0 else { throw AppError.usage("could not run command (\(String(cString: strerror(spawned))))") }

        // Wait without reaping first: once reaped, the pid can be reused, and the handler must
        // have let go of it by then.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 {
            let error = errno
            guard error == EINTR else {
                ChildSignals.target = 0
                throw Self.lostTrack(error)
            }
        }
        ChildSignals.target = 0
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            let error = errno
            guard error == EINTR else { throw Self.lostTrack(error) }
        }
        return ChildExit(waitStatus: status)
    }

    private static func lostTrack(_ error: Int32) -> AppError {
        .usage("lost track of the command (\(String(cString: strerror(error))))")
    }
}

/// INT, QUIT, TERM and HUP while a launched command runs: keys must outlive the command to
/// clean up after it, and passes on what was meant for the command.
enum ChildSignals {
    static let caught: [Int32] = [SIGINT, SIGQUIT, SIGTERM, SIGHUP]

    static var caughtSet: sigset_t {
        var set = sigset_t()
        sigemptyset(&set)
        for sig in caught { sigaddset(&set, sig) }
        return set
    }

    /// The child the handler passes signals to; 0 when none runs. This and `terminal` live in
    /// raw cells, not Swift variables: the handler can interrupt this thread in the middle of
    /// a write, and a variable's runtime exclusivity check would then trap.
    static var target: pid_t {
        get { cells[0] }
        set { cells[0] = newValue }
    }

    /// keys' controlling terminal, or -1. The terminal sends Ctrl-C to its foreground group
    /// wherever stdin and stdout point (`cmd </dev/null >log`), so it is asked directly.
    private static var terminal: Int32 {
        get { cells[1] }
        set { cells[1] = newValue }
    }

    nonisolated(unsafe) private static let cells: UnsafeMutablePointer<Int32> = {
        let cells = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        cells.initialize(repeating: 0, count: 2)
        cells[1] = -1
        return cells
    }()

    /// Who sent a signal, as far as it matters to `childAlreadyHasIt`.
    enum Sender {
        case kernel, sameSession, otherSession, gone
    }

    /// Ctrl-C and Ctrl-\ reach the terminal's whole foreground group, so while keys and the
    /// child are both in it, a copy from keys would arrive as a second signal, which many tools
    /// take as "quit now". macOS names the process that wrote the keystroke into the terminal
    /// (Terminal, iTerm, tmux, sshd) as the sender, and it is never in this session; a process
    /// in this session signalling keys alone, such as a batch runner stopping its child, is
    /// passed on, as is a sender that is already gone (kill(1)). The cost: `kill -INT` from a
    /// live process in another session looks like the keystroke and is dropped (TERM gets
    /// through). TERM and HUP are always passed on, so one sent to the whole job arrives twice.
    static func childAlreadyHasIt(_ sig: Int32, childInForeground: Bool, sender: Sender) -> Bool {
        guard sig == SIGINT || sig == SIGQUIT, childInForeground else { return false }
        switch sender {
        case .kernel, .otherSession: return true
        case .sameSession, .gone: return false
        }
    }

    /// Installs the forwarding handler on each signal keys did not inherit as ignored, and
    /// returns the actions it replaced. An inherited ignore (nohup, a script's background job)
    /// is left alone and reaches the command as it would without keys.
    static func install() -> [(signal: Int32, previous: sigaction)] {
        // First touched here rather than in a handler, which must not run its initializer.
        target = 0
        if terminal < 0 { terminal = open("/dev/tty", O_RDONLY | O_NOCTTY | O_CLOEXEC) }
        var replaced: [(signal: Int32, previous: sigaction)] = []
        for sig in caught {
            var current = sigaction()
            sigaction(sig, nil, &current)
            if let handler = current.__sigaction_u.__sa_handler,
               unsafeBitCast(handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
            {
                continue
            }
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = { sig, info, context in ChildSignals.forward(sig, info, context) }
            action.sa_flags = SA_SIGINFO | SA_RESTART
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
            replaced.append((sig, current))
        }
        return replaced
    }

    static func restore(_ replaced: [(signal: Int32, previous: sigaction)]) {
        for (sig, previous) in replaced {
            var previous = previous
            sigaction(sig, &previous, nil)
        }
        if terminal >= 0 {
            close(terminal)
            terminal = -1
        }
    }

    /// The child starts with an empty mask and every signal at its default, except the
    /// inherited ignores `install` kept.
    static func spawnAttributes(keptIgnored: [Int32]) -> posix_spawnattr_t? {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var defaults = sigset_t()
        sigfillset(&defaults)
        for sig in keptIgnored { sigdelset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        return attributes
    }

    /// Async-signal context: syscalls only, no allocation, errno left as found.
    private static func forward(_ sig: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _: UnsafeMutableRawPointer?) {
        let savedErrno = errno
        defer { errno = savedErrno }
        let child = target
        guard child > 0 else { return }
        // A child that made a group of its own (GNU timeout does) did not get the keystroke.
        let group = getpgrp()
        let childInForeground = terminal >= 0 && tcgetpgrp(terminal) == group && getpgid(child) == group
        let senderPID = info?.pointee.si_pid ?? 0
        let sender: Sender
        if senderPID <= 0 {
            sender = .kernel
        } else {
            let session = getsid(senderPID)
            // EPERM: in another session, which the caller may not look into.
            if session == -1 { sender = errno == EPERM ? .otherSession : .gone }
            else { sender = session == getsid(0) ? .sameSession : .otherSession }
        }
        if !childAlreadyHasIt(sig, childInForeground: childInForeground, sender: sender) {
            kill(child, sig)
        }
    }
}
