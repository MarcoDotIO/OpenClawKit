import Foundation
import OpenClawProtocol
import Testing
@testable import OpenClawCore

@Suite("OpenClaw JSON5")
struct OpenClawJSON5Tests {
    @Test
    func parsesJSON5Extensions() throws {
        let text = """
        // leading comment
        {
          unquoted: 'single',
          "double": "a\\u0041\\n",
          trailing: [1, 2, 3,],
          hex: 0x1F,
          leadingDot: .5,
          trailingDot: 5.,
          plus: +7,
          negativeHex: -0x10,
          exponent: 1e3,
          /* block
             comment */
          multi: 'line \\
        continued',
          $dollar_key: true,
          nothing: null,
        }
        """
        let value = try #require(try OpenClawJSON5.parse(text).dictionaryValue)
        #expect(value["unquoted"]?.stringValue == "single")
        #expect(value["double"]?.stringValue == "aA\n")
        #expect(value["trailing"]?.arrayValue?.compactMap(\.intValue) == [1, 2, 3])
        #expect(value["hex"]?.intValue == 31)
        #expect(value["leadingDot"]?.doubleValue == 0.5)
        #expect(value["trailingDot"]?.intValue == 5)
        #expect(value["plus"]?.intValue == 7)
        #expect(value["negativeHex"]?.intValue == -16)
        #expect(value["exponent"]?.intValue == 1_000)
        #expect(value["multi"]?.stringValue == "line continued")
        #expect(value["$dollar_key"]?.boolValue == true)
        #expect(value["nothing"]?.isNull == true)
    }

    @Test
    func strictModeRejectsJSON5Syntax() {
        for text in ["{a: 1}", "{\"a\": 1,}", "['x']", "{\"a\": 0x10}", "// c\n{}", "{\"a\": .5}", "{\"a\": 01}"] {
            #expect(throws: OpenClawJSON5.ParseError.self, "\(text)") {
                _ = try OpenClawJSON5.parse(text, allowJSON5: false)
            }
        }
        #expect((try? OpenClawJSON5.parse("{\"a\": [1, 2.5, \"x\", true, null]}", allowJSON5: false)) != nil)
    }

    @Test
    func reportsPositionsForMalformedInput() {
        do {
            _ = try OpenClawJSON5.parse("{\n  \"a\": 1\n  \"b\": 2\n}")
            Issue.record("expected a parse error")
        } catch let error as OpenClawJSON5.ParseError {
            #expect(error.line == 3)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(throws: OpenClawJSON5.ParseError.self) { _ = try OpenClawJSON5.parse("{\"a\": \"unterminated}") }
        #expect(throws: OpenClawJSON5.ParseError.self) { _ = try OpenClawJSON5.parse("{} trailing") }
        #expect(throws: OpenClawJSON5.ParseError.self) { _ = try OpenClawJSON5.parse("/* open") }
    }

    @Test
    func recordsAuthoredKeyOrderAndWritesItBack() throws {
        let text = #"{"zeta": {"b": 1, "a": 2}, "alpha": [{"y": 1, "x": 2}], "mid": 3}"#
        let parsed = try OpenClawJSON5.parseWithKeyOrder(Data(text.utf8))
        #expect(parsed.keyOrder.keys(at: []) == ["zeta", "alpha", "mid"])
        #expect(parsed.keyOrder.keys(at: ["zeta"]) == ["b", "a"])
        #expect(parsed.keyOrder.keys(at: ["alpha", "0"]) == ["y", "x"])
        let compact = OpenClawJSON5.serialize(parsed.value, keyOrder: parsed.keyOrder, prettyPrinted: false)
        #expect(compact == text.replacingOccurrences(of: " ", with: ""))
        let sorted = OpenClawJSON5.serialize(parsed.value, keyOrder: parsed.keyOrder, sortedKeys: true, prettyPrinted: false)
        #expect(sorted == #"{"alpha":[{"x":2,"y":1}],"mid":3,"zeta":{"a":2,"b":1}}"#)
    }

    @Test
    func prettyOutputMatchesJSONStringify() {
        let value = AnyCodable(.object([
            "a": AnyCodable(.array([AnyCodable(.int(1)), AnyCodable(.object([:]))])),
            "b": AnyCodable(.array([])),
            "c": AnyCodable(.string("quote\" slash\\ tab\t ctl\u{01} emoji 🦞 /")),
        ]))
        let expected = """
        {
          "a": [
            1,
            {}
          ],
          "b": [],
          "c": "quote\\" slash\\\\ tab\\t ctl\\u0001 emoji 🦞 /"
        }
        """
        #expect(OpenClawJSON5.serialize(value) == expected)
    }

    @Test
    func formatsNumbersLikeECMAScript() {
        #expect(OpenClawJSON5.formatNumber(0.1) == "0.1")
        #expect(OpenClawJSON5.formatNumber(1.5) == "1.5")
        #expect(OpenClawJSON5.formatNumber(1e21) == "1e+21")
        #expect(OpenClawJSON5.formatNumber(1e-7) == "1e-7")
        #expect(OpenClawJSON5.formatNumber(0.000001) == "0.000001")
        #expect(OpenClawJSON5.formatNumber(1.2345678901234568e20) == "123456789012345680000")
        #expect(OpenClawJSON5.formatNumber(-2.5e-10) == "-2.5e-10")
        #expect(OpenClawJSON5.formatNumber(.infinity) == "null")
    }

    @Test
    func largeIntegersKeepFidelityWhereAnyCodableCan() throws {
        let value = try #require(try OpenClawJSON5.parse(#"{"ms": 4102444800000, "huge": 18446744073709551615}"#).dictionaryValue)
        #expect(value["ms"]?.int64Value == 4_102_444_800_000)
        #expect(value["huge"]?.doubleValue == 1.8446744073709552e19)
    }

    #if canImport(Darwin)
    @Test
    func agreesWithFoundationJSON5OnDocsExamples() throws {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        for url in try ConfigFixtures.files(in: "docs", extension: "json5") {
            let data = try Data(contentsOf: url)
            let foundation = try? decoder.decode(AnyCodable.self, from: data)
            let ours = try? OpenClawJSON5.parse(data)
            #expect((foundation == nil) == (ours == nil), "\(url.lastPathComponent): parser disagreement")
            if let foundation, let ours {
                #expect(foundation == ours, "\(url.lastPathComponent): value disagreement")
            }
        }
    }
    #endif
}
