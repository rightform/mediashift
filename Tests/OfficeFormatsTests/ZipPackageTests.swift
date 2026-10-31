import ConversionCore
import Foundation
import Testing
import ZIPFoundation
@testable import OfficeFormats

@Suite("ZIP safety")
struct ZipPackageTests {
    @Test(arguments: [
        ("a/b.xml", "a/b.xml"),
        ("./a/b.xml", "a/b.xml"),
        ("a\\b.xml", "a/b.xml"),
    ])
    func keepsSafeNames(raw: String, expected: String) {
        #expect(ZipPackage.safeName(raw) == expected)
    }

    @Test(arguments: ["../evil.xml", "a/../../evil.xml", "/etc/passwd", "..\\evil.xml", "a//b", "", "a/", "a\0b"])
    func dropsUnsafeNames(raw: String) {
        #expect(ZipPackage.safeName(raw) == nil)
    }

    @Test func hidesEntriesThatTryToLeaveThePackage() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("a.zip")
        let archive = try Archive(url: url, accessMode: .create)
        for name in ["good.txt", "../evil.txt", "/absolute.txt", "x/../../evil2.txt"] {
            let data = Data("x".utf8)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            })
        }
        let package = try ZipPackage(url: url, formatName: "test")
        #expect(package.partNames == ["good.txt"])
    }

    @Test func stopsReadingAPartOverTheLimit() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("a.zip")
        // Highly compressible, like a real zip bomb: a megabyte of zeros in about a kilobyte.
        try ZipWriter.write([ZipWriter.Part("big.bin", Data(count: 1 << 20))], to: url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0 < 1 << 14)

        var limits = ZipLimits()
        limits.maxPartSize = 1 << 16
        let package = try ZipPackage(url: url, formatName: "test", limits: limits)
        #expect(throws: ConversionError.self) { try package.data(forPart: "big.bin") }
    }

    @Test func stopsReadingOverTheTotalLimit() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("a.zip")
        try ZipWriter.write(["a", "b", "c"].map { ZipWriter.Part($0, Data(count: 1000)) }, to: url)
        var limits = ZipLimits()
        limits.maxTotalSize = 2500
        let package = try ZipPackage(url: url, formatName: "test", limits: limits)
        _ = try package.data(forPart: "a")
        _ = try package.data(forPart: "b")
        #expect(throws: ConversionError.self) { try package.data(forPart: "c") }
    }

    @Test func refusesTooManyEntries() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("a.zip")
        try ZipWriter.write(["a", "b", "c"].map { ZipWriter.Part($0, Data()) }, to: url)
        var limits = ZipLimits()
        limits.maxEntryCount = 2
        #expect(throws: ConversionError.self) { try ZipPackage(url: url, formatName: "test", limits: limits) }
    }

    @Test func explainsPasswordProtectedOfficeFiles() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("a.xlsx")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0, 0, 0]).write(to: url)
        #expect(throws: ConversionError("This file is password protected or uses an old format.")) {
            try XLSXFormat.read(url)
        }
    }

    @Test func writerLeavesNoPartialFileBehind() throws {
        let folder = try TemporaryFolder()
        let missing = folder.url.appendingPathComponent("no-such-folder/a.zip")
        #expect(throws: ConversionError.self) {
            try ZipWriter.write([ZipWriter.Part("a", "b")], to: missing)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
    }

    @Test func writerReplacesAnExistingFile() throws {
        let folder = try TemporaryFolder()
        let url = folder.file("a.zip")
        try ZipWriter.write([ZipWriter.Part("first", "1")], to: url)
        try ZipWriter.write([ZipWriter.Part("second", "2")], to: url)
        #expect(try ZipPackage(url: url, formatName: "test").partNames == ["second"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["a.zip"])
    }

    @Test func directoryPackagesSkipSymbolicLinks() throws {
        let folder = try TemporaryFolder()
        let package = folder.file("doc.pages")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Index"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: package.appendingPathComponent("Index/a.iwa"))
        let outside = folder.file("secret.txt")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("Index/link.iwa"), withDestinationURL: outside)

        let directory = try DirectoryPackage(url: package)
        #expect(directory.partNames == ["Index/a.iwa"])
        #expect(try directory.data(forPart: "Index/link.iwa") == nil)
        #expect(try directory.data(forPart: "../secret.txt") == nil)
    }
}
