import Foundation
import OpenClawProtocol
import Testing

// Semantics adapted from upstream OpenClaw 2026.9.6 AnyCodableTests (PR #133707
// "stop JSON numbers becoming booleans") for the enum-backed, Sendable AnyCodable.
@Suite("AnyCodable fidelity")
struct AnyCodableFidelityTests {
    private struct Shape: Codable, Sendable, Equatable {
        let code: String
        let count: Int
    }

    @Test
    func jsonSerializationNumbersKeepTheirKinds() throws {
        let raw = try JSONSerialization.jsonObject(
            with: Data(#"{"a":1,"b":true,"c":1.0,"d":1700000000000,"e":0,"f":1.5,"g":false,"h":null}"#.utf8)
        )
        let object = try #require(AnyCodable.fromFoundation(raw)?.dictionaryValue)

        #expect(object["a"]?.value == .int(1))
        #expect(object["b"]?.value == .bool(true))
        #expect(object["c"]?.value == .int(1))
        #expect(object["d"]?.int64Value == 1_700_000_000_000)
        #expect(object["e"]?.value == .int(0))
        #expect(object["f"]?.value == .double(1.5))
        #expect(object["g"]?.value == .bool(false))
        #expect(object["h"]?.isNull == true)
        #expect(object["a"]?.boolValue == nil)
        #expect(object["e"]?.boolValue == nil)
        #expect(object["b"]?.intValue == nil)

        let viaSendableInit = AnyCodable(NSNumber(value: 1))
        #expect(viaSendableInit.value == .int(1))
        #expect(AnyCodable(NSNumber(value: true)).value == .bool(true))
        #expect(AnyCodable(NSNumber(value: 0.25)).value == .double(0.25))
    }

    @Test
    func epochMillisecondsRoundTripAcrossRepresentations() throws {
        let epochMs: Int64 = 1_800_000_000_000
        let representations: [AnyCodable] = [
            AnyCodable(epochMs),
            AnyCodable(NSNumber(value: epochMs)),
            try #require(AnyCodable.fromFoundation(JSONSerialization.jsonObject(with: Data("1800000000000".utf8), options: [.fragmentsAllowed]))),
            try JSONDecoder().decode(AnyCodable.self, from: Data("1800000000000".utf8)),
        ]
        for value in representations {
            #expect(value.int64Value == epochMs)
            #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == "1800000000000")
            #expect(try JSONDecoder().decode(Int64.self, from: JSONEncoder().encode(value)) == epochMs)
        }
        #expect(Set(representations).count == 1)
    }

    @Test(arguments: [Int64.min, -42, -1, 0, 1, 42, 9_007_199_254_740_993, Int64.max])
    func signedIntegersRoundTripExactlyOn64BitHosts(_ value: Int64) throws {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data(String(value).utf8))
        let native = AnyCodable(value)
        let bridged = AnyCodable(NSNumber(value: value))
        guard Int(exactly: value) != nil else {
            // 32-bit Int (watchOS arm64_32) stores out-of-range integers as `.double`.
            #expect(decoded.doubleValue != nil)
            return
        }
        #expect(decoded == native)
        #expect(bridged == native)
        #expect(native.int64Value == value)
        #expect(try JSONDecoder().decode(Int64.self, from: JSONEncoder().encode(native)) == value)
    }

    @Test(arguments: [false, true])
    func booleansNeverEqualNumbers(_ value: Bool) throws {
        let booleans = [
            AnyCodable(value),
            AnyCodable(NSNumber(value: value)),
            try JSONDecoder().decode(AnyCodable.self, from: Data((value ? "true" : "false").utf8)),
        ]
        let number = value ? 1 : 0
        let numbers = [
            AnyCodable(number),
            AnyCodable(NSNumber(value: number)),
            AnyCodable(Double(number)),
            try JSONDecoder().decode(AnyCodable.self, from: Data(String(number).utf8)),
        ]
        for boolean in booleans {
            #expect(boolean.boolValue == value)
            for numeric in numbers {
                #expect(numeric.boolValue == nil)
                #expect(boolean != numeric)
                #expect(Set([boolean, numeric]).count == 2)
            }
        }
    }

    @Test
    func integerAccessAcceptsOnlyExactInRangeValues() {
        let cases: [(AnyCodable, Int?)] = [
            (AnyCodable(0), 0),
            (AnyCodable(-1.0), -1),
            (AnyCodable(1.5), nil),
            (AnyCodable(Double(Int.max) * 2), nil),
            (AnyCodable(Double.infinity), nil),
            (AnyCodable(true), nil),
            (AnyCodable("1"), nil),
        ]
        for (value, expected) in cases {
            #expect(value.intValue == expected)
        }
        #expect(AnyCodable(Double(Int64.max) * 2).int64Value == nil)
        #expect(AnyCodable(3).doubleValue == 3)
    }

    @Test
    func typedAndFoundationValuesAreConvertedStructurally() throws {
        #expect(AnyCodable(NSNull()).value == .null)
        #expect(AnyCodable(Float(0.5)).value == .double(0.5))
        #expect(AnyCodable(Int32(7)).value == .int(7))
        #expect(AnyCodable(UInt8(255)).value == .int(255))
        #expect(AnyCodable(AnyCodable("wrapped")).value == .string("wrapped"))
        #expect(AnyCodable(AnySendableValue.bool(true)).value == .bool(true))
        #expect(AnyCodable(["a": 1, "b": 2]).value == .object(["a": AnyCodable(1), "b": AnyCodable(2)]))
        #expect(AnyCodable([["nested": true]]).arrayValue?.first?.dictionaryValue?["nested"] == AnyCodable(true))

        let shape = Shape(code: "INVALID_REQUEST", count: 2)
        let wrapped = AnyCodable(shape)
        #expect(wrapped.dictionaryValue?["code"] == AnyCodable("INVALID_REQUEST"))
        #expect(wrapped.dictionaryValue?["count"] == AnyCodable(2))
        #expect(try GatewayPayloadCodec.decode(Shape.self, from: wrapped) == shape)
        #expect(try AnyCodable(encoding: shape) == wrapped)

        let errorShape = ErrorShape(code: "UNAVAILABLE", message: "busy", retryable: true)
        #expect(AnyCodable(errorShape).dictionaryValue?["message"] == AnyCodable("busy"))

        let optional: String? = nil
        #expect(AnyCodable(optional).isNull)

        let foundation = NSDictionary(dictionary: [
            "rows": NSArray(array: [NSNumber(value: 1), NSNumber(value: true), NSNull(), "text"]),
        ])
        let converted = try #require(AnyCodable.fromFoundation(foundation))
        #expect(converted == AnyCodable([
            "rows": AnyCodable([AnyCodable(1), AnyCodable(true), AnyCodable.nullValue, AnyCodable("text")]),
        ]))
        #expect(converted.foundationValue is [String: Any])
    }

    @Test
    func nestedMixedPayloadsRoundTripThroughJSON() throws {
        struct Payload: Decodable, Equatable {
            let generation: Int64
            let enabled: Bool
            let fraction: Double
            let rows: [[Int64]]
        }

        let json = #"{"generation":1800000000000,"enabled":true,"fraction":0.5,"rows":[[-42,1],[0,42]]}"#
        let foundation = try #require(AnyCodable.fromFoundation(JSONSerialization.jsonObject(with: Data(json.utf8))))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        let expected = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))

        #expect(foundation == decoded)
        for value in [foundation, decoded] {
            #expect(try JSONDecoder().decode(Payload.self, from: JSONEncoder().encode(value)) == expected)
        }
    }
}
