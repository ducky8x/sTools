import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Backdrop

@Suite("Animation files")
struct BackdropAnimationFileTests {
    // MARK: - What kind of file it is

    @Test func aGIFIsKnownByItsHeaderWhateverItIsCalled() throws {
        let folder = TempFolder()
        let gif = TestMedia.writeGIF(to: folder.file("loop.bin"), colors: [.red, .green], delays: [0.1, 0.1])
        #expect(BackdropAnimationFile.kind(of: gif) == .gif)
    }

    @Test func anythingElseIsLeftToAVFoundation() throws {
        let folder = TempFolder()
        let other = folder.file("clip.mov")
        try Data("not a gif".utf8).write(to: other)
        #expect(BackdropAnimationFile.kind(of: other) == .video)
    }

    @Test func aFileThatCantBeReadHasNoKind() {
        let folder = TempFolder()
        #expect(BackdropAnimationFile.kind(of: folder.file("gone.mp4")) == nil)
    }

    // MARK: - Probing

    @Test func probingAGIFGivesItsSizeAndFirstFrame() async throws {
        let folder = TempFolder()
        let gif = TestMedia.writeGIF(to: folder.file("loop.gif"), colors: [.green, .red], delays: [0.1, 0.1], width: 30, height: 20)
        let info = try await BackdropAnimationFile.probe(gif).get()
        #expect(info.kind == .gif)
        #expect(info.size == CGSize(width: 30, height: 20))
        #expect(TestMedia.color(of: try #require(info.poster)) == .green)
    }

    @Test func probingAMovieGivesItsSizeAndFirstFrame() async throws {
        let folder = TempFolder()
        let movie = try await TestMedia.writeMovie(to: folder.file("loop.mp4"), colors: [.red, .blue])
        let info = try await BackdropAnimationFile.probe(movie).get()
        #expect(info.kind == .video)
        #expect(info.size == CGSize(width: 128, height: 96))
        let poster = try #require(info.poster)
        #expect(poster.width == 128 && poster.height == 96)
        // Video keeps colors only roughly (red comes back near 229, 33, 0).
        #expect(TestMedia.color(of: poster, x: 64, y: 48).isClose(to: .red, tolerance: 48), "the poster is the first frame, not the last")
    }

    @Test func probingARotatedMovieGivesThePictureTheWayUpItPlays() async throws {
        let folder = TempFolder()
        let movie = try await TestMedia.writeMovie(to: folder.file("portrait.mov"), colors: [.green], fileType: .mov,
                                                   transform: CGAffineTransform(rotationAngle: .pi / 2))
        let info = try await BackdropAnimationFile.probe(movie).get()
        #expect(info.size == CGSize(width: 96, height: 128))
        let poster = try #require(info.poster)
        #expect(poster.width == 96 && poster.height == 128, "the poster is turned upright too")
    }

    @Test func probingSkipsThePosterWhenAskedTo() async throws {
        let folder = TempFolder()
        let gif = TestMedia.writeGIF(to: folder.file("loop.gif"), colors: [.green, .red], delays: [0.1, 0.1])
        #expect(try await BackdropAnimationFile.probe(gif, wantsPoster: false).get().poster == nil)
    }

    @Test(arguments: ["notes.txt", "still.png", "empty.mp4", "gone.mov"])
    func probingSomethingThatIsNotPlayableFails(name: String) async throws {
        let folder = TempFolder()
        try Data("hello".utf8).write(to: folder.file("notes.txt"))
        try Data().write(to: folder.file("empty.mp4"))
        let png = TestMedia.solidImage(.red)
        let destination = try #require(CGImageDestinationCreateWithURL(folder.file("still.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, png, nil)
        #expect(CGImageDestinationFinalize(destination))

        let result = await BackdropAnimationFile.probe(folder.file(name))
        guard case .failure(let problem) = result else {
            Issue.record("\(name) shouldn't have been playable")
            return
        }
        #expect(problem.message == BackdropAnimationFile.cantPlayMessage)
    }

    // MARK: - Importing

    @Test func importingAGIFCopiesItIntoTheImagesFolder() async throws {
        let source = TempFolder(), images = TempFolder()
        let gif = TestMedia.writeGIF(to: source.file("My Loop.GIF"), colors: [.red, .green], delays: [0.1, 0.1])
        let name = try await BackdropAnimationFile.importAnimation(from: gif, into: images.url).get()
        #expect(name.hasPrefix("Images/") && name.hasSuffix(".gif"), "stored as Images/<id>.gif, the extension in lowercase")
        let copy = images.url.appending(path: (name as NSString).lastPathComponent)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: gif))
        #expect(BackdropSettings.Fill.validImageName(name) == name, "and the name is one the settings keep")
    }

    @Test(arguments: [("clip.mp4", AVFileType.mp4), ("clip.mov", AVFileType.mov), ("clip.m4v", AVFileType.m4v)])
    func importingAMovieKeepsItsFormat(fileName: String, fileType: AVFileType) async throws {
        let source = TempFolder(), images = TempFolder()
        let movie = try await TestMedia.writeMovie(to: source.file(fileName), colors: [.red, .blue], fileType: fileType)
        let name = try await BackdropAnimationFile.importAnimation(from: movie, into: images.url).get()
        #expect(name.hasSuffix("." + (fileName as NSString).pathExtension))
        #expect(try Data(contentsOf: images.url.appending(path: (name as NSString).lastPathComponent)) == Data(contentsOf: movie))
    }

    @Test func eachImportGetsAFreshName() async throws {
        let source = TempFolder(), images = TempFolder()
        let gif = TestMedia.writeGIF(to: source.file("loop.gif"), colors: [.red, .green], delays: [0.1, 0.1])
        let first = try await BackdropAnimationFile.importAnimation(from: gif, into: images.url).get()
        let second = try await BackdropAnimationFile.importAnimation(from: gif, into: images.url).get()
        #expect(first != second)
    }

    @Test func aFileWithNoExtensionGetsOneFromWhatItIs() async throws {
        let source = TempFolder(), images = TempFolder()
        let gif = TestMedia.writeGIF(to: source.file("loop"), colors: [.red, .green], delays: [0.1, 0.1])
        #expect(try await BackdropAnimationFile.importAnimation(from: gif, into: images.url).get().hasSuffix(".gif"))
    }

    @Test func aFileThatCantBePlayedIsNotCopiedAndSaysWhy() async throws {
        let source = TempFolder(), images = TempFolder()
        let text = source.file("notes.mp4")
        try Data("hello".utf8).write(to: text)
        let result = await BackdropAnimationFile.importAnimation(from: text, into: images.url)
        guard case .failure(let problem) = result else {
            Issue.record("a text file isn't a movie")
            return
        }
        #expect(problem.message == BackdropAnimationFile.cantPlayMessage)
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.url.path).isEmpty)
    }

    @Test func aFileOverTheLimitIsNotCopiedAndSaysWhy() async throws {
        let source = TempFolder(), images = TempFolder()
        let gif = TestMedia.writeGIF(to: source.file("loop.gif"), colors: [.red, .green], delays: [0.1, 0.1])
        let size = try #require(try gif.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let result = await BackdropAnimationFile.importAnimation(from: gif, into: images.url, maximumBytes: size - 1)
        guard case .failure(let problem) = result else {
            Issue.record("the file is one byte over the limit")
            return
        }
        #expect(problem.message == BackdropAnimationFile.tooBigMessage(maximumBytes: size - 1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.url.path).isEmpty)
        let fits = await BackdropAnimationFile.importAnimation(from: gif, into: images.url, maximumBytes: size)
        #expect((try? fits.get()) != nil, "a file exactly the size of the limit still goes in")
    }

    @Test func theLimitIsWrittenInMegabytes() {
        #expect(BackdropAnimationFile.maximumBytes == 200 * 1_048_576)
        #expect(BackdropAnimationFile.tooBigMessage(maximumBytes: BackdropAnimationFile.maximumBytes)
            == "That file is larger than 200 MB. Choose a smaller or shorter one.")
    }

    @Test func theMessagesAreShortAndPlain() {
        #expect(BackdropAnimationFile.cantPlayMessage == "sTools can\u{2019}t play that file. Choose a GIF or a video such as MP4 or MOV.")
    }
}
