import Foundation
import Testing

/// A throwaway copy of the repository for `scripts/publish-update.sh`, with a fake GitHub around it: a stand-in `gh`
/// that answers from small files and writes down its calls, stand-ins for the build scripts and Sparkle's tools, and a
/// bare git repository as `origin`. Nothing built from it reaches the network, the keychain, GitHub or the real
/// repository, and the script runs with a home folder of its own.
final class PublishFixture {
    let folder: URL
    var home: URL { folder.appending(path: "home") }
    var origin: URL { folder.appending(path: "origin.git") }
    var root: URL { folder.appending(path: "repo") }
    /// What the imaginary ducky8x/sTools holds: one small file per fact.
    var github: URL { folder.appending(path: "github") }
    var log: URL { folder.appending(path: "calls.log") }
    var outputs: URL { home.appending(path: "Projects/App Outputs") }
    var script: URL { root.appending(path: "scripts/publish-update.sh") }
    /// Where the script leaves the feed and the notes it publishes.
    func published(_ tag: String) -> URL { root.appending(path: "build/publish/\(tag)") }

    private(set) var headSHA = ""

    /// Three commits on `main`, all pushed to `origin`, so the build number is 1003: the count plus 1000.
    init(visibility: String = "PRIVATE") async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "sTools-publish-\(UUID().uuidString)")
        for name in ["home", "tmp", "github", "origin.git", "repo"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        try write("ducky8x\n", "github/login")
        try write("\(visibility)\n", "github/visibility")
        try write("", "github/tags")
        try write("", "github/latest")
        try write("", "github/commits")

        // The real scripts under test, and stand-ins for everything that builds, signs or reads a feed with Sparkle.
        try copyFromRepository("scripts/publish-update.sh", executable: true)
        try copyFromRepository("scripts/appcast-add-item.sh", executable: true)
        // The libraries every real script sources, and the real build script under another name (`scripts/build-app.sh`
        // is a stand-in here), which `runRealBuildApp` stops before it builds anything.
        let libraries = repositoryRoot.appending(path: "scripts/lib")
        for name in try FileManager.default.contentsOfDirectory(atPath: libraries.path) {
            try copyFromRepository("scripts/lib/\(name)")
        }
        try write(String(contentsOf: repositoryRoot.appending(path: "scripts/build-app.sh"), encoding: .utf8),
                  "repo/scripts/real-build-app.sh", executable: true)
        try copyFromRepository("packaging/appcast-template.xml")
        try copyFromRepository("packaging/sparkle-public-key.txt")
        try write(FakeScripts.buildApp, "repo/scripts/build-app.sh", executable: true)
        try write(FakeScripts.buildDMG, "repo/scripts/build-dmg.sh", executable: true)
        try write(FakeScripts.checkAppcast, "repo/scripts/check-appcast.sh", executable: true)
        try write(FakeScripts.checkNoHomePaths, "repo/scripts/check-no-home-paths.sh", executable: true)
        try write("build/\n.build/\n", "repo/.gitignore")
        try write(FakeScripts.gh, "bin/gh", executable: true)
        try write(FakeScripts.git, "bin/git", executable: true)
        try write(FakeScripts.swift, "bin/swift", executable: true)
        let sparkle = "repo/.build/artifacts/sparkle/Sparkle/bin"
        try write(FakeScripts.signUpdate, "\(sparkle)/sign_update", executable: true)
        try write(FakeScripts.generateKeys, "\(sparkle)/generate_keys", executable: true)

        try await git(["init", "-q", "--bare", "-b", "main"], in: origin)
        try await git(["init", "-q", "-b", "main"])
        try await git(["remote", "add", "origin", origin.path])
        try await commit("Start the repository")
        try await commit("Second commit")
        try await commit("Third commit")
        try await git(["push", "-q", "origin", "main"])
        headSHA = try await git(["rev-parse", "HEAD"])
        try write("\(headSHA)\n", "github/commits")
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    // MARK: Files

    func write(_ text: String, _ path: String, executable: Bool = false) throws {
        let url = folder.appending(path: path)
        if executable {
            try writeExecutable(text, to: url)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func copyFromRepository(_ path: String, executable: Bool = false) throws {
        try write(String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8), "repo/\(path)", executable: executable)
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// Every call the script made to the fake `gh`, `git` and the build scripts, one per line.
    var calls: String { (try? read(log)) ?? "" }

    // MARK: Git

    var gitEnvironment: [String: String] {
        [
            "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        ]
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try await runScript(URL(filePath: "/usr/bin/git"), ["-C", (directory ?? root).path] + arguments,
                                         environment: gitEnvironment, timeout: .seconds(60))
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")) failed: \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A commit that changes one tracked file.
    func commit(_ message: String) async throws {
        try write("\(message)\n", "repo/notes.txt")
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", message])
    }

    /// Every ref in `origin` with its commit, to show that a run changed nothing there.
    func originRefs() async throws -> String {
        try await git(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin)
    }

    // MARK: The fake GitHub

    /// One earlier release, v0.2.0 (build 773, the 0.2.0 beta's), whose feed holds that version.
    func addEarlierRelease() async throws {
        let notes = folder.appending(path: "old-notes.md")
        try "The second beta.\n".write(to: notes, atomically: true, encoding: .utf8)
        let template = repositoryRoot.appending(path: "packaging/appcast-template.xml").path
        let url = "https://github.com/ducky8x/sTools/releases/download/v0.2.0/sTools-0.2.0-macOS.dmg"
        let signature = Data(repeating: 3, count: 64).base64EncodedString()
        let feed = try await runScript(
            repositoryRoot.appending(path: "scripts/appcast-add-item.sh"),
            [template, "0.2.0", "773", "15.0", url, "1000", signature, notes.path],
            environment: gitEnvironment, timeout: .seconds(60))
        try #require(feed.status == 0, "\(feed.output)")
        try write(feed.output, "github/files/v0.2.0/appcast.xml")
        try write("v0.2.0\n", "github/tags")
        try write("v0.2.0\n", "github/latest")
        try write("false\tfalse\n", "github/flags/v0.2.0")
        try write("sTools-0.2.0-macOS.dmg 1000\nappcast.xml 1\n", "github/assets/v0.2.0")
    }

    // MARK: Running the script

    /// Runs `scripts/publish-update.sh` with these arguments. `environment` adds to the fake world's own.
    func run(_ arguments: [String], environment extra: [String: String] = [:]) async throws -> ScriptResult {
        var environment = gitEnvironment
        environment["PATH"] = "\(folder.appending(path: "bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TMPDIR"] = folder.appending(path: "tmp").path + "/"
        environment["FAKE_LOG"] = log.path
        environment["FAKE_GITHUB"] = github.path
        environment.merge(extra) { _, new in new }
        return try await runScript(script, arguments, environment: environment, currentDirectory: root)
    }
}

extension PublishFixture {
    /// The real `scripts/build-app.sh` in this checkout, for a debug build signed ad hoc. The `swift` in the fake world
    /// refuses to build, so the script stops right after it names the build's number; nothing is built or signed.
    func runRealBuildApp() async throws -> ScriptResult {
        var environment = gitEnvironment
        environment["PATH"] = "\(folder.appending(path: "bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TMPDIR"] = folder.appending(path: "tmp").path + "/"
        environment["FAKE_LOG"] = log.path
        return try await runScript(root.appending(path: "scripts/real-build-app.sh"), ["debug", "--adhoc"],
                                   environment: environment, currentDirectory: root, timeout: .seconds(120))
    }
}

/// The stand-ins. Each writes its call to `$FAKE_LOG`.
enum FakeScripts {
    /// swift, which will not build: `scripts/build-app.sh` stops at it.
    static let swift = #"""
    #!/bin/sh
    echo "swift $*" >> "$FAKE_LOG"
    echo "fake swift: not building" >&2
    exit 1
    """#

    /// The GitHub CLI. It knows only the calls `publish-update.sh` makes, and answers from `$FAKE_GITHUB`.
    static let gh = #"""
    #!/bin/sh
    echo "gh $*" >> "$FAKE_LOG"
    g="$FAKE_GITHUB"
    fail() { echo "$*" >&2; exit 1; }
    # The word after a flag.
    flag_value() {
        flag="$1"; shift
        while [ $# -gt 0 ]; do
            if [ "$1" = "$flag" ]; then echo "$2"; return; fi
            shift
        done
    }
    case "$1" in
    api)
        case "$2" in
        user) cat "$g/login" ;;
        repos/*/releases/latest)
            [ -s "$g/latest" ] || fail "gh: Not Found (HTTP 404)"
            cat "$g/latest" ;;
        repos/*/commits/*)
            sha="${2##*/}"
            grep -qx "$sha" "$g/commits" || fail "gh: No commit found for SHA: $sha (HTTP 422)"
            echo "$sha" ;;
        *) fail "fake gh: unexpected call: $*" ;;
        esac ;;
    repo) cat "$g/visibility" ;;
    release)
        case "$2" in
        view)
            tag="$3"
            case "$tag" in -*) tag="" ;; esac
            if [ -z "$tag" ]; then
                tag=$(cat "$g/latest" 2>/dev/null)
                [ -n "$tag" ] || fail "release not found"
            fi
            grep -qx "$tag" "$g/tags" 2>/dev/null || fail "release not found"
            case "$(flag_value --json "$@")" in
            tagName) echo "$tag" ;;
            isDraft,isPrerelease) cat "$g/flags/$tag" ;;
            assets) cat "$g/assets/$tag" ;;
            *) fail "fake gh: unexpected call: $*" ;;
            esac ;;
        download)
            tag="$3"
            dir=$(flag_value --dir "$@")
            [ -f "$g/files/$tag/appcast.xml" ] || fail "no assets match the file pattern"
            cp "$g/files/$tag/appcast.xml" "${dir:-.}/appcast.xml" ;;
        create)
            tag="$3"; shift 3
            latest=0; prerelease=false; draft=false; files=""
            while [ $# -gt 0 ]; do
                case "$1" in
                --repo|--target|--title|--notes-file|--notes) shift 2 ;;
                --latest) latest=1; shift ;;
                --prerelease) prerelease=true; shift ;;
                --draft) draft=true; shift ;;
                -*) shift ;;
                *) files="$files
    $1"; shift ;;
                esac
            done
            mkdir -p "$g/files/$tag" "$g/assets" "$g/flags"
            : > "$g/assets/$tag"
            printf '%s\n' "$files" | while IFS= read -r f; do
                [ -n "$f" ] || continue
                echo "$(basename "$f") $(wc -c < "$f" | tr -d ' ')" >> "$g/assets/$tag"
                cp "$f" "$g/files/$tag/$(basename "$f")"
            done
            echo "$tag" >> "$g/tags"
            printf '%s\t%s\n' "$draft" "$prerelease" > "$g/flags/$tag"
            if [ "$latest" = 1 ] && [ "$draft" = false ] && [ "$prerelease" = false ]; then
                echo "$tag" > "$g/latest"
                # Anyone can read the feed at the Latest address only while the repository is public.
                if [ "$(cat "$g/visibility")" = PUBLIC ] && [ -z "$FAKE_NO_LIVE_FEED" ]; then
                cp "$g/files/$tag/appcast.xml" "$g/live-feed"
            fi
            fi
            echo "https://github.com/ducky8x/sTools/releases/tag/$tag" ;;
        *) fail "fake gh: unexpected call: $*" ;;
        esac ;;
    *) fail "fake gh: unexpected call: $*" ;;
    esac
    """#

    /// git, with the commands that change a repository or its remote refused: the script may look, never write.
    static let git = #"""
    #!/bin/sh
    echo "git $*" >> "$FAKE_LOG"
    for word in "$@"; do
        case "$word" in
        push|tag|commit|merge|rebase|reset|checkout|switch|stash|add|rm|mv|clean|cherry-pick|revert)
            echo "fake git: the script must not run git $word" >&2
            exit 97 ;;
        esac
    done
    exec /usr/bin/git "$@"
    """#

    /// Sparkle's sign_update: the line it prints, with a fixed signature and the file's size.
    static let signUpdate = #"""
    #!/bin/sh
    echo "sign_update $*" >> "$FAKE_LOG"
    if [ "$1" = "--account" ]; then shift 2; fi
    if [ "$1" = "--verify" ]; then exit 0; fi
    echo "sparkle:edSignature=\"RkFLRVNJR05BVFVSRQ==\" length=\"$(wc -c < "$1" | tr -d ' ')\""
    """#

    /// Sparkle's generate_keys -p: the public key, which is the committed one.
    static let generateKeys = #"""
    #!/bin/sh
    echo "generate_keys $*" >> "$FAKE_LOG"
    cat "$(dirname "$0")/../../../../../packaging/sparkle-public-key.txt"
    """#

    /// A release build: an app with the Info.plist keys the script reads.
    static let buildApp = #"""
    #!/bin/sh
    echo "build-app $* VERSION=$VERSION BUILD_NUMBER=$BUILD_NUMBER" >> "$FAKE_LOG"
    root=$(cd "$(dirname "$0")/.." && pwd)
    key=$(head -n 1 "$root/packaging/sparkle-public-key.txt")
    mkdir -p "$root/build/sTools.app/Contents"
    cat > "$root/build/sTools.app/Contents/Info.plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>SUFeedURL</key><string>https://github.com/ducky8x/sTools/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>$key</string>
    </dict></plist>
    EOF
    """#

    /// The DMG: a file of the right name in the shared output folder (the fake home's).
    static let buildDMG = #"""
    #!/bin/sh
    echo "build-dmg $*" >> "$FAKE_LOG"
    root=$(cd "$(dirname "$0")/.." && pwd)
    version=$(plutil -extract CFBundleShortVersionString raw "$root/build/sTools.app/Contents/Info.plist")
    suffix=""
    [ "$1" = "--beta" ] && suffix="-beta"
    mkdir -p "$HOME/Projects/App Outputs"
    head -c 4096 /dev/zero > "$HOME/Projects/App Outputs/sTools-$version$suffix-macOS.dmg"
    """#

    /// The home-path check: passes, or fails when `$FAKE_HOME_CHECK_FAILS` is set.
    static let checkNoHomePaths = #"""
    #!/bin/sh
    echo "check-no-home-paths $*" >> "$FAKE_LOG"
    if [ -n "$FAKE_HOME_CHECK_FAILS" ]; then
        echo "error: 1 place holds a home-folder path (listed above); this must not ship" >&2
        exit 1
    fi
    echo "    nothing found"
    """#

    /// Sparkle's reader of a feed (the real one needs Sparkle): prints what the real one prints, from the feed's text.
    /// `--live` reads the feed the fake GitHub serves to anyone, which exists only for a public repository.
    static let checkAppcast = #"""
    #!/bin/sh
    echo "check-appcast $*" >> "$FAKE_LOG"
    expect=""; file=""; live=0
    while [ $# -gt 0 ]; do
        case "$1" in
        --expect) expect="$2"; shift 2 ;;
        --live) live=1; shift ;;
        *) file="$1"; shift ;;
        esac
    done
    if [ "$live" = 1 ]; then
        file="$FAKE_GITHUB/live-feed"
        [ -f "$file" ] || { echo "error: the feed could not be fetched (HTTP 404)" >&2; exit 1; }
    fi
    echo "Sparkle read the feed: $(grep -c '<item>' "$file") item(s)"
    lines=$(awk '
    /<item>/ { build = ""; short = ""; min = ""; url = ""; signed = "NO EdDSA signature" }
    /<sparkle:version>/ { build = $0; sub(/.*<sparkle:version>/, "", build); sub(/<.*/, "", build) }
    /<sparkle:shortVersionString>/ { short = $0; sub(/.*<sparkle:shortVersionString>/, "", short); sub(/<.*/, "", short) }
    /<sparkle:minimumSystemVersion>/ { min = $0; sub(/.*<sparkle:minimumSystemVersion>/, "", min); sub(/<.*/, "", min) }
    /<enclosure / { url = $0; sub(/.*url="/, "", url); sub(/".*/, "", url); if ($0 ~ /sparkle:edSignature=/) signed = "EdDSA signature" }
    /<\/item>/ { printf "  %s (build %s), macOS %s or newer, %s, %s\n", short, build, min, url, signed }
    ' "$file")
    [ -z "$lines" ] || echo "$lines"
    if [ -n "$expect" ]; then
        echo "$lines" | grep -q "^  $expect (build " || { echo "error: the feed does not list version $expect" >&2; exit 1; }
    fi
    """#
}
