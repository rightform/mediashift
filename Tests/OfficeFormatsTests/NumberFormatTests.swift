import Testing
@testable import OfficeFormats

@Suite("Number formats")
struct NumberFormatTests {
    @Test(arguments: [
        (0.125, "0.00%", "12.50%"),
        (0.5, "0%", "50%"),
        (1234.5, "#,##0.00", "1,234.50"),
        (1234567.891, "#,##0", "1,234,568"),
        (-5, "0.00", "-5.00"),
        (-5, "0.00;(0.00)", "(5.00)"),
        (-1234, "#,##0_);[Red](#,##0)", "(1,234)"),
        (1234, "#,##0_);[Red](#,##0)", "1,234"),
        (0, "0.00;-0.00;\"nil\"", "nil"),
        (3.14159, "0.0", "3.1"),
        (1.005, "0.00", "1.01"),
        (5, "000", "005"),
        (0, "#", ""),
        (0.5, "#.##", ".5"),
        (1234.5, "#,##0.00 \"zł\"", "1,234.50 zł"),
        (1234.5, "[$€-407] #,##0.00", "€ 1,234.50"),
        (5551234, "###-####", "555-1234"),
        (1500000, "#,##0,\"k\"", "1,500k"),
        (150, "[>=100]\"big\";[<100]\"small\"", "big"),
        (50, "[>=100]\"big\";[<100]\"small\"", "small"),
    ] as [(Double, String, String)])
    func numbers(value: Double, code: String, expected: String) {
        #expect(NumberFormat(code: code).string(for: value) == expected)
    }

    @Test(arguments: [
        (45000, "yyyy-mm-dd", "2023-03-15"),
        (45000, "dd.mm.yyyy", "15.03.2023"),
        (45000, "d mmm yyyy", "15 Mar 2023"),
        (45000, "dddd, mmmm d, yyyy", "Wednesday, March 15, 2023"),
        (45000.5, "yyyy-mm-dd hh:mm:ss", "2023-03-15 12:00:00"),
        (0.75, "h:mm AM/PM", "6:00 PM"),
        (0.75, "hh:mm", "18:00"),
        (1.5, "[h]:mm", "36:00"),
        (0.000011574, "mm:ss.000", "00:01.000"),
        (1, "yyyy-mm-dd", "1900-01-01"),
        (59, "yyyy-mm-dd", "1900-02-28"),
        (61, "yyyy-mm-dd", "1900-03-01"),
    ] as [(Double, String, String)])
    func dates(value: Double, code: String, expected: String) {
        #expect(NumberFormat(code: code).string(for: value) == expected)
    }

    @Test func nineteenFourDateSystem() {
        #expect(NumberFormat(code: "yyyy-mm-dd").string(for: 0, date1904: true) == "1904-01-01")
    }

    @Test(arguments: [
        (0.30000000000000004, "0.3"),
        (1234.5, "1234.5"),
        (123456789012345, "123456789012345"),
        (1e15, "1E+15"),
        (1.5e300, "1.5E+300"),
        (0.000012, "0.000012"),
        (-7, "-7"),
    ] as [(Double, String)])
    func general(value: Double, expected: String) {
        #expect(NumberFormat.general.string(for: value) == expected)
    }

    @Test func scientificAndFractions() {
        #expect(NumberFormat(code: "0.00E+00").string(for: 12345) == "1.23E+04")
        #expect(NumberFormat(code: "##0.0E+0").string(for: 12345) == "12.3E+3")
        #expect(NumberFormat(code: "# ?/?").string(for: 2.5) == "2 1/2")
        #expect(NumberFormat(code: "# ??/??").string(for: 0.75) == "3/4")
        #expect(NumberFormat(code: "# ?/8").string(for: 1.25) == "1 2/8")
    }

    @Test func textPlaceholder() {
        #expect(NumberFormat(code: "@").string(forText: "abc") == "abc")
        #expect(NumberFormat(code: "\"id: \"@").string(forText: "abc") == "id: abc")
        #expect(NumberFormat(code: "0.00").string(forText: "abc") == "abc")
        #expect(NumberFormat(code: "@").string(for: 12) == "12")
    }

    @Test func malformedCodesDoNotCrash() {
        for code in ["", ";", ";;;;", "[", "\"", "\\", "E+", "/", "0/", "_", "*", "[h", "yyyy[", ".", ",", "%%%"] {
            _ = NumberFormat(code: code).string(for: 1234.5)
            _ = NumberFormat(code: code).string(for: -1)
            _ = NumberFormat(code: code).string(forText: "x")
        }
    }

    @Test func builtInIDs() {
        #expect(NumberFormat.builtInCode(id: 14) == "yyyy-mm-dd")
        #expect(NumberFormat.builtInCode(id: 9) == "0%")
        #expect(NumberFormat.builtInCode(id: 500) == nil)
    }
}

@Suite("Number format extremes")
struct NumberFormatExtremeTests {
    @Test(arguments: [1e300, -1e300, 1e-300, 1.7976931348623157e308, 5e-324, 3e6, 2.9e6])
    func extremeValuesDoNotCrash(value: Double) {
        let codes = [
            "0.00", "#,##0", "0%", "0.00E+00", "##0.0E+0", "# ?/?", "# ????????????/????????????", "# ?/99999999999999999999",
            "yyyy-mm-dd", "[h]:mm:ss", "ss." + String(repeating: "0", count: 400), "General", "@",
            String(repeating: "0", count: 400) + "." + String(repeating: "0", count: 400),
        ]
        for code in codes {
            _ = NumberFormat(code: code).string(for: value)
        }
    }
}
