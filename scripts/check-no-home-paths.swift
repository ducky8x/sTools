// The check behind scripts/check-no-home-paths.sh, which compiles and runs this file; that script says what is
// looked for, where, and why. It is Swift for zlib (which checks deflate data strictly, so chance matches in binary
// data are thrown out at once), the Compression framework (LZFSE, LZ4 and xz) and speed on disk images of tens of
// megabytes.
//
// Usage: check-no-home-paths [--provenance] <file-or-folder>...
//
// Nothing it looks for is ever printed: a finding names a label ("the account name") and a count, and everything
// printed has those values replaced by placeholders such as <account name>.
//
// Exit status: 0 when nothing was found, 1 when something was, 2 when the check could not run.

import Compression
import Darwin
import Foundation
import IOKit
import zlib

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Printing without giving anything away

/// Values that must never be printed, with what is printed instead; longest first once set up.
var masks: [(value: String, placeholder: String)] = []

func masked(_ text: String) -> String {
    masks.reduce(text) { $0.replacingOccurrences(of: $1.value, with: $1.placeholder, options: .caseInsensitive) }
}

func printError(_ line: String) {
    FileHandle.standardError.write(Data((masked(line) + "\n").utf8))
}

/// Ends the check without a verdict.
func broken(_ message: String) -> Never {
    printError("error: \(message)")
    exit(2)
}

/// A reason the check cannot finish.
struct Broken: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - What must not ship

@inline(__always) func lowercasedASCII(_ byte: UInt8) -> UInt8 { byte &- 0x41 < 26 ? byte | 0x20 : byte }
@inline(__always) func isASCIILetter(_ byte: UInt8) -> Bool { (byte | 0x20) &- 0x61 < 26 }

/// One byte pattern to look for. `unit` is 2 for UTF-16 text, in the byte order `bigEndian` gives, else 1.
struct Form: Hashable {
    let bytes: [UInt8]
    var unit = 1
    var bigEndian = false
}

struct Needle {
    enum Match {
        /// Text in any letter case, also inside words; found as UTF-8 and as UTF-16, and with %XX, &#NN; and
        /// backslash escapes decoded.
        case text
        /// A short name, found only as a word of its own (no ASCII letter right before or after it), as it is
        /// written, in lower case, in upper case or capitalized; as UTF-8 and as UTF-16.
        case word
        /// Raw bytes.
        case binary
    }

    let label: String
    let forms: [Form]
    let match: Match
    /// Six characters or more (binary: bytes): long enough not to turn up by chance in binary data. Shorter
    /// needles are looked for only in a file's own bytes and in unpacked data that is text.
    let isLong: Bool
}

func utf16(_ text: String, bigEndian: Bool) -> [UInt8] {
    text.utf16.flatMap { unit in
        bigEndian ? [UInt8(unit >> 8), UInt8(unit & 0xFF)] : [UInt8(unit & 0xFF), UInt8(unit >> 8)]
    }
}

func variants(_ text: String) -> [String] {
    [text, text.precomposedStringWithCanonicalMapping, text.decomposedStringWithCanonicalMapping]
}

/// `.text` forms: UTF-8 with ASCII letters lowercased, as the text they are searched in. ASCII text stored as
/// UTF-16 is found by dropping NUL bytes before searching; text beyond ASCII also gets UTF-16 forms.
func textForms(_ values: [String]) -> [Form] {
    var forms = Set<Form>()
    for value in values {
        for variant in variants(value) {
            for cased in [variant, variant.lowercased(), variant.uppercased()] {
                forms.insert(Form(bytes: cased.utf8.map(lowercasedASCII)))
                guard cased.unicodeScalars.contains(where: { !$0.isASCII }) else { continue }
                for bigEndian in [false, true] {
                    forms.insert(Form(bytes: utf16(cased, bigEndian: bigEndian).map(lowercasedASCII), unit: 2,
                                      bigEndian: bigEndian))
                }
            }
        }
    }
    return forms.filter { !$0.bytes.isEmpty }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
}

/// `.word` forms: exact bytes, UTF-8 and UTF-16, in the four usual letter cases.
func wordForms(_ values: [String]) -> [Form] {
    var forms = Set<Form>()
    for value in values {
        for variant in variants(value) {
            for cased in [variant, variant.lowercased(), variant.uppercased(), variant.capitalized] {
                forms.insert(Form(bytes: Array(cased.utf8)))
                for bigEndian in [false, true] {
                    forms.insert(Form(bytes: utf16(cased, bigEndian: bigEndian), unit: 2, bigEndian: bigEndian))
                }
            }
        }
    }
    return forms.filter { !$0.bytes.isEmpty }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
}

var needles: [Needle] = []

/// Looks for `values` under `label`: as words when any is shorter than six characters, else as text.
func addText(_ label: String, placeholder: String?, values: [String]) {
    let values = Array(Set(values.filter { !$0.isEmpty })).sorted()
    guard let shortest = values.map(\.count).min() else { return }
    let isLong = shortest >= 6
    needles.append(Needle(label: label, forms: isLong ? textForms(values) : wordForms(values),
                          match: isLong ? .text : .word, isLong: isLong))
    if let placeholder { masks += values.map { ($0, placeholder) } }
}

func addBinary(_ label: String, _ bytes: [UInt8]) {
    guard bytes.count >= 6, bytes.contains(where: { $0 != 0 }) else { return }
    needles.append(Needle(label: label, forms: [Form(bytes: bytes)], match: .binary, isLong: true))
}

func addUUID(_ label: String, _ text: String?) {
    guard let text, let uuid = UUID(uuidString: text) else { return }
    let string = uuid.uuidString
    addText(label, placeholder: "<UUID>", values: [string, string.replacingOccurrences(of: "-", with: "")])
    addBinary(label, withUnsafeBytes(of: uuid.uuid) { Array($0) })
}

let account = NSUserName()
if account.isEmpty { broken("cannot read the account name") }

/// A full name as it is, run together (also with . _ -), last name first, and each part of three letters or more on
/// its own.
func addName(_ name: String, label: String, partLabel: String, placeholder: String) {
    let parts = name.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    guard !parts.isEmpty, !(parts.count == 1 && parts[0].lowercased() == account.lowercased()) else { return }
    var forms = [name]
    for order in parts.count > 1 ? [parts, parts.reversed()] : [parts] {
        forms += [" ", "", ".", "_", "-"].map { order.joined(separator: $0) }
    }
    if parts.count > 1 { forms.append(parts.reversed().joined(separator: ", ")) }
    addText(label, placeholder: placeholder, values: forms)
    for part in parts where part.count >= 3 && part.lowercased() != account.lowercased() {
        addText(partLabel, placeholder: placeholder, values: [part])
    }
}

addText("\"/Users/\"", placeholder: nil, values: ["/Users/"])
addText("\"/var/folders/\"", placeholder: nil, values: ["/var/folders/"])
addText("the account name", placeholder: "<account name>", values: [account])

var homes = Set<String>()
for home in [NSHomeDirectory(), ProcessInfo.processInfo.environment["HOME"] ?? ""] where home.count > 1 {
    homes.insert(home)
    homes.insert(URL(fileURLWithPath: home).resolvingSymlinksInPath().path)
}
addText("the home folder's path", placeholder: "<home folder>", values: Array(homes))
addText("the home folder's name", placeholder: "<home folder name>",
        values: homes.map { ($0 as NSString).lastPathComponent }
            .filter { $0.count >= 3 && $0.lowercased() != account.lowercased() })

addName(NSFullUserName(), label: "the full name", partLabel: "a part of the full name", placeholder: "<full name>")
for name in (ProcessInfo.processInfo.environment["CHECK_NO_HOME_PATHS_EXTRA_NAMES"] ?? "").split(separator: "\n") {
    addName(String(name), label: "an extra name", partLabel: "a part of an extra name", placeholder: "<extra name>")
}

var temporaryIDs: [String] = []
for name in [_CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR] {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard confstr(name, &buffer, buffer.count) > 0 else { continue }
    // /var/folders/<xx>/<id>/T/
    let components = String(cString: buffer).split(separator: "/").map(String.init)
    if let index = components.firstIndex(of: "folders"), index + 2 < components.count {
        temporaryIDs.append(components[index + 2])
    }
}
addText("this user's temporary folder id", placeholder: "<temporary folder id>",
        values: temporaryIDs.filter { $0.count >= 6 })

typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mbr_uid_to_uuid") {
    var bytes = [UInt8](repeating: 0, count: 16)
    if unsafeBitCast(symbol, to: UIDToUUID.self)(getuid(), &bytes) == 0 {
        addUUID("this user's UUID", NSUUID(uuidBytes: bytes).uuidString)
    }
}

let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
if platform != 0 {
    func property(_ key: String) -> String? {
        IORegistryEntryCreateCFProperty(platform, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            as? String
    }
    addUUID("this Mac's hardware UUID", property(kIOPlatformUUIDKey))
    if let serial = property(kIOPlatformSerialNumberKey), serial.count >= 8 {
        addText("this Mac's serial number", placeholder: "<serial number>", values: [serial])
    }
    IOObjectRelease(platform)
}
for volume in ["/", "/System/Volumes/Data"] {
    addUUID("this Mac's volume UUID",
            try? URL(fileURLWithPath: volume).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
}

let provenanceAttribute = "com.apple.provenance"

/// The id macOS stamps, in a com.apple.provenance extended attribute (01 02 00, then 8 bytes), on every file this
/// process makes when it descends from an app macOS tracks; nil when it does not.
func ownProvenanceID() -> [UInt8]? {
    var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("check-no-home-paths.XXXXXX")
        .utf8CString)
    let descriptor = mkstemp(&template)
    guard descriptor >= 0 else { return nil }
    defer {
        close(descriptor)
        unlink(template)
    }
    var value = [UInt8](repeating: 0, count: 64)
    guard fgetxattr(descriptor, provenanceAttribute, &value, value.count, 0, 0) == 11 else { return nil }
    return Array(value[3..<11])
}
if let id = ownProvenanceID() { addBinary("this Mac's provenance id", id) }

masks.sort { $0.value.count > $1.value.count }

// MARK: - Searching

/// Where `form` starts in `bytes`, not overlapping; for a word, only where no ASCII letter touches either end.
func positions(of form: Form, in bytes: UnsafeRawBufferPointer, word: Bool) -> [Int] {
    guard let base = bytes.baseAddress, !form.bytes.isEmpty, bytes.count >= form.bytes.count else { return [] }
    return form.bytes.withUnsafeBytes { pattern -> [Int] in
        var found: [Int] = []
        var offset = 0
        while offset + pattern.count <= bytes.count,
              let hit = memmem(base + offset, bytes.count - offset, pattern.baseAddress!, pattern.count) {
            let at = base.distance(to: UnsafeRawPointer(hit))
            let end = at + pattern.count
            if !word || (isBoundary(bytes, before: at, form) && isBoundary(bytes, after: end, form)) {
                found.append(at)
                offset = end
            } else {
                offset = at + 1
            }
        }
        return found
    }
}

/// Whether the character before `at` (or after `end`) is not an ASCII letter, read as `form` is encoded.
func isBoundary(_ bytes: UnsafeRawBufferPointer, before at: Int, _ form: Form) -> Bool {
    if form.unit == 1 { return at == 0 || !isASCIILetter(bytes[at - 1]) }
    guard at >= 2 else { return true }
    let (high, low) = form.bigEndian ? (bytes[at - 2], bytes[at - 1]) : (bytes[at - 1], bytes[at - 2])
    return !(high == 0 && isASCIILetter(low))
}

func isBoundary(_ bytes: UnsafeRawBufferPointer, after end: Int, _ form: Form) -> Bool {
    if form.unit == 1 { return end >= bytes.count || !isASCIILetter(bytes[end]) }
    guard end + 2 <= bytes.count else { return true }
    let (high, low) = form.bigEndian ? (bytes[end], bytes[end + 1]) : (bytes[end + 1], bytes[end])
    return !(high == 0 && isASCIILetter(low))
}

func count(_ form: Form, in bytes: [UInt8]) -> Int {
    bytes.withUnsafeBytes { positions(of: form, in: $0, word: false).count }
}

@inline(__always) func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x41...0x46: byte - 0x37
    case 0x61...0x66: byte - 0x57
    default: nil
    }
}

let xmlEntities: [String: UInt32] = ["amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27]

func appendUTF8(_ scalar: UInt32, to bytes: inout [UInt8]) -> Bool {
    guard let scalar = Unicode.Scalar(scalar) else { return false }
    bytes += Array(String(Character(scalar)).utf8)
    return true
}

/// `text` with %XX, &#NN; &#xHH; &amp; (and the other XML entities), \/ \\ \" \' \uXXXX and \xHH decoded, or nil
/// when it holds none.
func unescaped(_ text: [UInt8]) -> [UInt8]? {
    guard var index = text.firstIndex(where: { $0 == 0x25 || $0 == 0x26 || $0 == 0x5C }) else { return nil }
    var out = Array(text[..<index])
    out.reserveCapacity(text.count)
    var changed = false
    func hexNumber(_ start: Int, _ length: Int) -> UInt32? {
        guard start + length <= text.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<length {
            guard let digit = hexValue(text[start + offset]) else { return nil }
            value = value << 4 | UInt32(digit)
        }
        return value
    }
    while index < text.count {
        let byte = text[index]
        switch byte {
        case 0x25:  // %XX
            if let value = hexNumber(index + 1, 2) {
                out.append(UInt8(value))
                index += 3
                changed = true
                continue
            }
        case 0x26:  // &...;
            if let end = text[index..<min(text.count, index + 12)].firstIndex(of: 0x3B) {
                let body = String(decoding: text[(index + 1)..<end], as: UTF8.self)
                var scalar: UInt32?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    scalar = UInt32(body.dropFirst(2), radix: 16)
                } else if body.hasPrefix("#") {
                    scalar = UInt32(body.dropFirst(), radix: 10)
                } else {
                    scalar = xmlEntities[body.lowercased()]
                }
                if let scalar, appendUTF8(scalar, to: &out) {
                    index = end + 1
                    changed = true
                    continue
                }
            }
        case 0x5C:  // backslash escapes
            if index + 1 < text.count {
                let next = text[index + 1]
                if next == 0x2F || next == 0x5C || next == 0x22 || next == 0x27 {
                    out.append(next)
                    index += 2
                    changed = true
                    continue
                }
                if next | 0x20 == 0x78, let value = hexNumber(index + 2, 2) {  // \xHH
                    out.append(UInt8(value))
                    index += 4
                    changed = true
                    continue
                }
                if next | 0x20 == 0x75, let unit = hexNumber(index + 2, 4) {  // \uXXXX, with surrogate pairs
                    var scalar = unit
                    var length = 6
                    if (0xD800..<0xDC00).contains(unit), index + 11 < text.count, text[index + 6] == 0x5C,
                       text[index + 7] | 0x20 == 0x75, let low = hexNumber(index + 8, 4), (0xDC00..<0xE000).contains(low) {
                        scalar = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        length = 12
                    }
                    if appendUTF8(scalar, to: &out) {
                        index += length
                        changed = true
                        continue
                    }
                }
            }
        default:
            break
        }
        out.append(byte)
        index += 1
    }
    return changed ? out : nil
}

/// The forms of one buffer that needles are searched in, each made when first needed.
final class Views {
    let raw: UnsafeRawBufferPointer
    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    /// For UTF-16 forms of text beyond ASCII.
    lazy var lowerRaw: [UInt8] = raw.map(lowercasedASCII)
    /// NUL bytes dropped, so ASCII text stored as UTF-16 reads as ASCII; ASCII letters lowercased.
    lazy var lowerText: [UInt8] = {
        var text: [UInt8] = []
        text.reserveCapacity(raw.count)
        for byte in raw where byte != 0 { text.append(lowercasedASCII(byte)) }
        return text
    }()
    lazy var lowerUnescaped: [UInt8]? = unescaped(lowerText)?.map(lowercasedASCII)
}

/// Whether bytes look like text: mostly printable ASCII once NUL bytes (UTF-16) are set aside.
func isTextLike(_ bytes: UnsafeRawBufferPointer) -> Bool {
    guard !bytes.isEmpty else { return false }
    var nonNUL = 0
    var printable = 0
    for byte in bytes where byte != 0 {
        nonNUL += 1
        if (0x20...0x7E).contains(byte) || byte == 0x09 || byte == 0x0A || byte == 0x0D { printable += 1 }
    }
    return nonNUL * 100 >= bytes.count * 45 && printable * 100 >= nonNUL * 85
}

/// A few bytes on either side of a hit, printable, with the hit itself left out.
func context(_ bytes: UnsafeRawBufferPointer, at: Int, length: Int) -> String {
    func render(_ range: Range<Int>) -> String {
        range.map { index -> String in
            let byte = bytes[index]
            if (0x20...0x7E).contains(byte) && byte != 0x5C { return String(UnicodeScalar(byte)) }
            return String(format: "\\x%02X", byte)
        }.joined()
    }
    return "\"" + render(max(0, at - 16)..<at) + "<...>" + render((at + length)..<min(bytes.count, at + length + 16)) + "\""
}

// MARK: - Decoding

@inline(__always) func littleEndian16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> Int {
    Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
}

@inline(__always) func littleEndian32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}

@inline(__always) func bigEndian32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
    bytes.withUnsafeBytes { UInt32(zlib.crc32(0, $0.baseAddress?.assumingMemoryBound(to: Bytef.self), uInt($0.count))) }
}

/// Whether the raw deflate data at `start` can begin with a valid block header: rules out most chance matches
/// before trying to unpack them.
func plausibleDeflate(_ bytes: UnsafeRawBufferPointer, _ start: Int) -> Bool {
    guard start + 5 <= bytes.count else { return false }
    let first = bytes[start]
    switch (first >> 1) & 3 {
    case 0:  // stored: LEN and NLEN, on the next byte boundary, are each other's complement
        return littleEndian16(bytes, start + 1) == (~littleEndian16(bytes, start + 3) & 0xFFFF)
    case 1:  // fixed Huffman codes
        return true
    case 2:  // dynamic: at most 286 literal/length codes and 30 distance codes
        return Int(first >> 3) <= 29 && Int(bytes[start + 1] & 0x1F) <= 29
    default:
        return false
    }
}

/// Where the deflate data of the gzip member at `start` begins.
func gzipDataStart(_ bytes: UnsafeRawBufferPointer, _ start: Int) -> Int? {
    let flags = bytes[start + 3]
    guard flags & 0xE0 == 0 else { return nil }
    var position = start + 10
    if flags & 0x04 != 0 {
        guard position + 2 <= bytes.count else { return nil }
        position += 2 + littleEndian16(bytes, position)
    }
    for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
        while position < bytes.count, bytes[position] != 0 { position += 1 }
        position += 1
    }
    if flags & 0x02 != 0 { position += 2 }
    return position < bytes.count ? position : nil
}

let base64Values: [Int8] = (0..<256).map { value in
    switch UInt8(value) {
    case 0x41...0x5A: Int8(value - 0x41)
    case 0x61...0x7A: Int8(value - 0x61 + 26)
    case 0x30...0x39: Int8(value - 0x30 + 52)
    case 0x2B: 62
    case 0x2F: 63
    default: -1
    }
}

@inline(__always) func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

func decodeBase64<S: Sequence>(_ symbols: S) -> [UInt8] where S.Element == UInt8 {
    var decoded: [UInt8] = []
    var group: UInt32 = 0
    var count = 0
    for byte in symbols {
        let value = base64Values[Int(byte)]
        guard value >= 0 else { continue }
        group = group << 6 | UInt32(value)
        count += 1
        if count == 4 {
            decoded += [UInt8(group >> 16 & 0xFF), UInt8(group >> 8 & 0xFF), UInt8(group & 0xFF)]
            group = 0
            count = 0
        }
    }
    if count == 3 { decoded += [UInt8(group >> 10 & 0xFF), UInt8(group >> 2 & 0xFF)] }
    if count == 2 { decoded.append(UInt8(group >> 4 & 0xFF)) }
    return decoded
}

/// Calls `body` with every property list <data> element in `bytes`, decoded (`true`), and every other run of 24
/// or more base64 characters, decoded (`false`: it may not be base64 at all).
func forEachBase64(in bytes: UnsafeRawBufferPointer, _ body: ([UInt8], Bool) throws -> Void) rethrows {
    let open = Array("<data>".utf8)
    let close = Array("</data>".utf8)
    func matches(_ tag: [UInt8], at index: Int) -> Bool {
        index + tag.count <= bytes.count && (0..<tag.count).allSatisfy { lowercasedASCII(bytes[index + $0]) == tag[$0] }
    }
    var index = 0
    while index < bytes.count {
        if bytes[index] == 0x3C, matches(open, at: index) {
            let start = index + open.count
            var end = start
            while end < bytes.count, bytes[end] != 0x3C { end += 1 }
            if matches(close, at: end) {
                try body(decodeBase64(UnsafeRawBufferPointer(rebasing: bytes[start..<end])), true)
                index = end + close.count
                continue
            }
            index += 1
            continue
        }
        guard base64Values[Int(bytes[index])] >= 0 else {
            index += 1
            continue
        }
        let start = index
        while index < bytes.count, base64Values[Int(bytes[index])] >= 0 { index += 1 }
        if index - start >= 24 {
            try body(decodeBase64(UnsafeRawBufferPointer(rebasing: bytes[start..<index])), false)
        }
    }
}

/// Calls `body` with every run of 32 or more hex digits in `bytes`, decoded from its first and from its second
/// digit.
func forEachHexRun(in bytes: UnsafeRawBufferPointer, _ body: ([UInt8]) throws -> Void) rethrows {
    var index = 0
    while index < bytes.count {
        guard hexValue(bytes[index]) != nil else {
            index += 1
            continue
        }
        let start = index
        while index < bytes.count, hexValue(bytes[index]) != nil { index += 1 }
        guard index - start >= 32 else { continue }
        for shift in 0...1 {
            var decoded: [UInt8] = []
            var position = start + shift
            while position + 1 < index {
                decoded.append(hexValue(bytes[position])! << 4 | hexValue(bytes[position + 1])!)
                position += 2
            }
            try body(decoded)
        }
    }
}

// MARK: - Scanning

/// What one place holds: per needle, how many times as it is and how many times inside unpacked or decoded data,
/// and where short needles were found.
struct Tally {
    var direct: [Int: Int] = [:]
    var encoded: [Int: [String: Int]] = [:]
    var contexts: [Int: [String]] = [:]
    var isEmpty: Bool { direct.isEmpty && encoded.isEmpty }

    mutating func add(_ needle: Int, _ count: Int, via: String?) {
        guard count > 0 else { return }
        if let via {
            encoded[needle, default: [:]][via, default: 0] += count
        } else {
            direct[needle, default: 0] += count
        }
    }
}

struct TooMuchData: Error {}

final class Scanner {
    /// Data in data in data...: a disk image holds an app, whose asset catalog holds LZFSE streams, which hold
    /// pictures. Deeper than this, nothing is unpacked.
    static let maximumDepth = 5
    /// Bytes unpacked per place at most; a disk image of this app unpacks to well under a gigabyte.
    static let unpackLimit = 4 << 30

    enum Source {
        /// A file's own bytes.
        case file
        /// A compressed stream that unpacked completely and passed its checksum, or a property list's <data>.
        case unpacked
        /// Text that looked like base64 or hex: possibly noise, so only long needles are looked for, and nothing
        /// in it is decoded further except checked streams.
        case decoded
    }

    var budget = 0
    var unpacked = 0

    func scan(_ raw: UnsafeRawBufferPointer, depth: Int = 0, source: Source = .file, via: String? = nil,
              skipBinaryNeedles: Bool = false, tally: inout Tally) throws {
        let views = Views(raw)
        let shortNeedles = source == .file || (source == .unpacked && isTextLike(raw))
        for (index, needle) in needles.enumerated() where needle.isLong || shortNeedles {
            var total = 0
            switch needle.match {
            case .binary:
                guard !skipBinaryNeedles else { continue }
                total = needle.forms.reduce(0) { $0 + positions(of: $1, in: raw, word: false).count }
            case .word:
                for form in needle.forms {
                    let hits = positions(of: form, in: raw, word: true)
                    total += hits.count
                    for at in hits.prefix(2) where tally.contexts[index, default: []].count < 3 {
                        tally.contexts[index, default: []].append(context(raw, at: at, length: form.bytes.count)
                            + (via.map { " in \($0) data" } ?? ""))
                    }
                }
            case .text:
                for form in needle.forms {
                    if form.unit == 2 {
                        total += count(form, in: views.lowerRaw)
                    } else {
                        total += max(count(form, in: views.lowerText), views.lowerUnescaped.map { count(form, in: $0) } ?? 0)
                    }
                }
            }
            tally.add(index, total, via: via)
        }
        guard depth < Self.maximumDepth else { return }

        func inside(_ kind: String) -> String { via.map { "\(kind) in \($0)" } ?? kind }
        try forEachStream(in: raw) { output, kind in
            try output.withUnsafeBytes {
                try scan($0, depth: depth + 1, source: .unpacked, via: inside(kind), tally: &tally)
            }
        }
        guard source != .decoded else { return }
        try forEachBase64(in: raw) { output, isPropertyListData in
            try output.withUnsafeBytes {
                try scan($0, depth: depth + 1, source: isPropertyListData ? .unpacked : .decoded, via: inside("base64"),
                         tally: &tally)
            }
        }
        try forEachHexRun(in: raw) { output in
            try output.withUnsafeBytes {
                try scan($0, depth: depth + 1, source: .decoded, via: inside("hex"), tally: &tally)
            }
        }
    }

    /// Inflates the deflate data starting at `start` with zlib (`windowBits` 15: zlib, 31: gzip, -15: raw): what
    /// came out and how many bytes it took, or nil unless it ended properly. zlib and gzip data must also pass
    /// their checksums.
    func inflateStream(_ bytes: UnsafeRawBufferPointer, from start: Int,
                       windowBits: Int32) throws -> (output: [UInt8], used: Int)? {
        guard start < bytes.count, let base = bytes.baseAddress else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: base.advanced(by: start).assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(min(bytes.count - start, Int(UInt32.max)))
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let status = chunk.withUnsafeMutableBytes { space -> Int32 in
                stream.next_out = space.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(space.count)
                return zlib.inflate(&stream, Z_NO_FLUSH)
            }
            output.append(contentsOf: chunk[0..<(chunk.count - Int(stream.avail_out))])
            if output.count > budget { throw TooMuchData() }
            switch status {
            case Z_STREAM_END: return (output, Int(stream.total_in))
            case Z_OK: continue
            default: return nil
            }
        }
    }

    /// Unpacks the stream of `algorithm` starting at `start`: what came out and how many bytes it took, or nil
    /// unless it ended properly.
    func unpack(_ bytes: UnsafeRawBufferPointer, from start: Int,
                algorithm: compression_algorithm) throws -> (output: [UInt8], used: Int)? {
        guard start < bytes.count, let base = bytes.baseAddress else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(stream) }
        let size = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        stream.pointee.src_ptr = UnsafePointer(base.advanced(by: start).assumingMemoryBound(to: UInt8.self))
        stream.pointee.src_size = bytes.count - start
        var output: [UInt8] = []
        while true {
            let before = stream.pointee.src_size
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = size
            let status = compression_stream_process(stream, Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = size - stream.pointee.dst_size
            output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced))
            if output.count > budget { throw TooMuchData() }
            switch status {
            case COMPRESSION_STATUS_END:
                return (output, bytes.count - start - stream.pointee.src_size)
            case COMPRESSION_STATUS_OK where produced > 0 || stream.pointee.src_size != before:
                continue
            default:
                return nil
            }
        }
    }

    /// Calls `body` with every compressed stream in `bytes` that unpacks completely and, where its format has one,
    /// passes its checksum: zlib (PNG chunks, disk image blocks), gzip, zip entries, LZFSE and LZVN (asset catalogs),
    /// LZ4 and xz. Streams that follow one another directly (a disk image's blocks) are joined, so text split
    /// between them is found too.
    func forEachStream(in bytes: UnsafeRawBufferPointer, _ body: ([UInt8], String) throws -> Void) throws {
        var pending: (kind: String, end: Int, output: [UInt8])?
        func flush() throws {
            if let finished = pending {
                pending = nil
                budget -= finished.output.count
                unpacked += finished.output.count
                try body(finished.output, finished.kind)
            }
        }
        var index = 0
        while index + 6 <= bytes.count {
            let first = bytes[index]
            let second = bytes[index + 1]
            var found: (kind: String, output: [UInt8], end: Int)?
            if first & 0x0F == 8, first >> 4 <= 7, (Int(first) << 8 | Int(second)) % 31 == 0, second & 0x20 == 0,
               plausibleDeflate(bytes, index + 2),
               let result = try inflateStream(bytes, from: index, windowBits: 15) {
                found = ("zlib", result.output, index + result.used)
            } else if first == 0x1F, second == 0x8B, bytes[index + 2] == 8, index + 18 <= bytes.count,
                      let data = gzipDataStart(bytes, index), plausibleDeflate(bytes, data),
                      let result = try inflateStream(bytes, from: index, windowBits: 31) {
                found = ("gzip", result.output, index + result.used)
            } else if first == 0x50, second == 0x4B, bytes[index + 2] == 3, bytes[index + 3] == 4,
                      index + 30 <= bytes.count, littleEndian16(bytes, index + 8) == 8 {
                let flags = littleEndian16(bytes, index + 6)
                let data = index + 30 + littleEndian16(bytes, index + 26) + littleEndian16(bytes, index + 28)
                if data < bytes.count, plausibleDeflate(bytes, data),
                   let result = try inflateStream(bytes, from: data, windowBits: -15) {
                    var end = data + result.used
                    var expected: UInt32? = flags & 0x08 == 0 ? littleEndian32(bytes, index + 14) : nil
                    if expected == nil, end + 4 <= bytes.count {  // a data descriptor follows
                        if bigEndian32(bytes, end) == 0x504B_0708, end + 8 <= bytes.count { end += 4 }
                        expected = littleEndian32(bytes, end)
                    }
                    if expected == crc32(result.output) { found = ("zip", result.output, end) }
                }
            } else if first == 0x62, second == 0x76, bytes[index + 2] == 0x78,
                      [0x32, 0x31, 0x6E].contains(bytes[index + 3]),  // bvx2 bvx1 bvxn
                      let result = try unpack(bytes, from: index, algorithm: COMPRESSION_LZFSE) {
                found = (bytes[index + 3] == 0x6E ? "LZVN" : "LZFSE", result.output, index + result.used)
            } else if first == 0x62, second == 0x76, bytes[index + 2] == 0x34, bytes[index + 3] == 0x31,  // bv41
                      let result = try unpack(bytes, from: index, algorithm: COMPRESSION_LZ4) {
                found = ("LZ4", result.output, index + result.used)
            } else if first == 0xFD, second == 0x37, bytes[index + 2] == 0x7A, bytes[index + 3] == 0x58,
                      bytes[index + 4] == 0x5A, bytes[index + 5] == 0,
                      let result = try unpack(bytes, from: index, algorithm: COMPRESSION_LZMA) {
                found = ("xz", result.output, index + result.used)
            }
            guard let found, !found.output.isEmpty else {
                index += 1
                continue
            }
            if let previous = pending, previous.kind == found.kind, previous.end == index {
                pending!.output += found.output
                pending!.end = found.end
            } else {
                try flush()
                pending = (found.kind, found.end, found.output)
            }
            index = max(index + 1, found.end)
        }
        try flush()
    }
}

// MARK: - Walking what ships

var arguments = Array(CommandLine.arguments.dropFirst())
var checkProvenance = false
if arguments.first == "--provenance" {
    checkProvenance = true
    arguments.removeFirst()
}
if arguments.isEmpty { broken("usage: scripts/check-no-home-paths.sh [--provenance] <file-or-folder>...") }

let scanner = Scanner()
var findings = 0
var items = 0
var bytesRead = 0

/// Prints what one place holds, one entry per label.
func report(_ place: String, _ tally: Tally, extra: [String] = []) {
    guard !tally.isEmpty || !extra.isEmpty else { return }
    var order: [String] = []
    var totals: [String: (all: Int, encoded: [String: Int], contexts: [String])] = [:]
    for (index, needle) in needles.enumerated() {
        let encoded = tally.encoded[index] ?? [:]
        let all = (tally.direct[index] ?? 0) + encoded.values.reduce(0, +)
        guard all > 0 else { continue }
        if totals[needle.label] == nil { order.append(needle.label) }
        totals[needle.label, default: (0, [:], [])].all += all
        totals[needle.label]!.encoded.merge(encoded, uniquingKeysWith: +)
        totals[needle.label]!.contexts += tally.contexts[index] ?? []
    }
    var parts = order.map { label -> String in
        let (all, encoded, _) = totals[label]!
        var text = "\(label) \(all) \(all == 1 ? "time" : "times")"
        if !encoded.isEmpty {
            text += " (" + encoded.sorted { $0.key < $1.key }.map { "\($0.value) in \($0.key) data" }
                .joined(separator: ", ") + ")"
        }
        return text
    }
    parts += extra
    printError("    \(place): " + parts.joined(separator: ", "))
    for label in order {
        for line in totals[label]!.contexts.prefix(3) { printError("        \(label) as a word: \(line)") }
    }
    findings += 1
}

func check(_ bytes: UnsafeRawBufferPointer, place: String, skipBinaryNeedles: Bool = false) throws {
    var tally = Tally()
    scanner.budget = Scanner.unpackLimit
    do {
        try scanner.scan(bytes, skipBinaryNeedles: skipBinaryNeedles, tally: &tally)
    } catch is TooMuchData {
        throw Broken("\(place) unpacks to more than \(Scanner.unpackLimit >> 30) GB; it cannot be checked")
    }
    report(place, tally)
}

func check(text: String, place: String) throws {
    try Array(text.utf8).withUnsafeBytes { try check($0, place: place) }
}

func attributeNames(_ path: String) -> [String]? {
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size >= 0 else { return nil }
    guard size > 0 else { return [] }
    var buffer = [CChar](repeating: 0, count: size)
    guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) == size else { return nil }
    return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}

func attributeValue(_ path: String, _ name: String) -> [UInt8]? {
    let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard size >= 0 else { return nil }
    var value = [UInt8](repeating: 0, count: size)
    guard size == 0 || getxattr(path, name, &value, size, 0, XATTR_NOFOLLOW) == size else { return nil }
    return value
}

/// Checks the item at `path` (shown as `place`): its name, its contents or link target, its extended attributes
/// and, for a folder, everything in it. Symbolic links are not followed.
func walk(_ path: String, place: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw Broken("cannot read \(place)") }
    items += 1
    try check(text: (place as NSString).lastPathComponent, place: "\(place) (its name)")
    switch info.st_mode & S_IFMT {
    case S_IFLNK:
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            throw Broken("cannot read the link \(place)")
        }
        try check(text: target, place: "\(place) (link target)")
    case S_IFREG:
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            throw Broken("cannot read \(place)")
        }
        try data.withUnsafeBytes { try check($0, place: place) }
        bytesRead += data.count
    default:
        break
    }
    guard let names = attributeNames(path) else { throw Broken("cannot list the extended attributes of \(place)") }
    for name in names {
        try check(text: name, place: "\(place) (extended attribute name)")
        guard let value = attributeValue(path, name) else {
            throw Broken("cannot read the extended attribute \(name) of \(place)")
        }
        let isProvenance = name == provenanceAttribute
        // A provenance attribute holds this Mac's provenance id by definition; --provenance decides about it.
        try value.withUnsafeBytes {
            try check($0, place: "\(place) (extended attribute \(name))", skipBinaryNeedles: isProvenance)
        }
        if isProvenance, checkProvenance, value.dropFirst(3).contains(where: { $0 != 0 }) {
            report("\(place) (extended attribute \(name))", Tally(),
                   extra: ["a provenance id (macOS stamps it on files made by apps it tracks)"])
        }
    }
    if info.st_mode & S_IFMT == S_IFDIR {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            throw Broken("cannot list everything in \(place)")
        }
        for entry in entries.sorted() {
            try walk((path as NSString).appendingPathComponent(entry), place: "\(place)/\(entry)")
        }
    }
}

var checked: [String] = []
do {
    let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for argument in arguments {
        let url = URL(fileURLWithPath: argument, relativeTo: here).standardizedFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Broken("nothing at \(argument)") }
        checked.append(url.lastPathComponent)
        try walk(url.path, place: url.lastPathComponent)
    }
} catch let error as Broken {
    broken(error.message)
}

let lookedFor = needles.map(\.label).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    + (checkProvenance ? ["a provenance id in com.apple.provenance"] : [])
if findings > 0 {
    printError("error: \(findings) \(findings == 1 ? "place holds" : "places hold") a home-folder path, a name or a "
        + "trace of this Mac (listed above); this must not ship")
    printError("    looked for: " + lookedFor.joined(separator: ", "))
    exit(1)
}
print(masked(String(format: "    nothing found in %@ (%d %@, %.1f MB read, %.1f MB unpacked)",
                    checked.joined(separator: ", "), items, items == 1 ? "item" : "items",
                    Double(bytesRead) / 1_000_000, Double(scanner.unpacked) / 1_000_000)))
print("    looked for: " + lookedFor.joined(separator: ", "))
