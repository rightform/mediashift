import ConversionCore
import Foundation
import Testing

@Test func outputKeepsTheNameAndChangesTheExtension() {
    let input = URL(fileURLWithPath: "/nonexistent/folder/report.docx")
    #expect(OutputNaming.outputURL(for: input, format: .pdf).lastPathComponent == "report.pdf")
}

@Test func outputNeverReusesAnExistingName() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("photo.png")
    try Data().write(to: input)
    #expect(OutputNaming.outputURL(for: input, format: .png).lastPathComponent == "photo-2.png")
}

@Test func recognizesAliasesInAnyCase() {
    #expect(FileFormat(fileExtension: "JPG") == .jpeg)
    #expect(FileFormat(fileExtension: "Markdown") == .md)
    #expect(FileFormat(fileExtension: "exe") == nil)
}

@Test func aTypedSuffixBecomesASafePartOfAName() {
    #expect(OutputNaming.cleanSuffix("web") == "web")
    #expect(OutputNaming.cleanSuffix("  web  ") == "web")
    #expect(OutputNaming.cleanSuffix("-web-") == "web")
    #expect(OutputNaming.cleanSuffix("../../etc") == "etc")
    #expect(OutputNaming.cleanSuffix("a/b:c") == "abc")
    #expect(OutputNaming.cleanSuffix("dla klienta") == "dla klienta")
    #expect(OutputNaming.cleanSuffix("") == nil)
    #expect(OutputNaming.cleanSuffix(" / : ") == nil)
    #expect(OutputNaming.cleanSuffix(String(repeating: "x", count: 100))?.count == 40)
}

@Test func aFolderOfResultsCarriesTheSuffixToo() {
    let input = URL(fileURLWithPath: "/tmp/none-such-folder/report.pdf")
    #expect(OutputNaming.outputFolder(for: input, suffix: "web").lastPathComponent == "report-web")
    #expect(OutputNaming.outputFolder(for: input).lastPathComponent == "report")
}
