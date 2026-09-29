import Foundation
import OpenClawModels
import Testing

// CoreAITensor validation is platform-neutral: decoded or mutated tensors must be rejected with a
// thrown error before they reach CoreAI (where a bad byte count or a negative dimension traps).

@Suite("CoreAI tensor validation")
struct CoreAITensorValidationTests {
    private func decode(_ json: String) throws -> CoreAITensor {
        try JSONDecoder().decode(CoreAITensor.self, from: Data(json.utf8))
    }

    @Test
    func decodingValidatesShapeAndByteCount() throws {
        let valid = try CoreAITensor(int32: [1, 2, 3, 4], shape: [2, 2])
        #expect(try JSONDecoder().decode(CoreAITensor.self, from: JSONEncoder().encode(valid)) == valid)

        // A negative dimension with empty data used to pass the byte check (0 == 0) and trap in NDArray.
        #expect(throws: DecodingError.self) { _ = try self.decode(#"{"shape":[-1],"scalarType":"int32","data":""}"#) }
        // An element count that saturated to Int.max used to overflow `count * byteWidth` and trap.
        #expect(throws: DecodingError.self) {
            _ = try self.decode(#"{"shape":[4611686018427387904,4],"scalarType":"int32","data":""}"#)
        }
        #expect(throws: DecodingError.self) { _ = try self.decode(#"{"shape":[2],"scalarType":"int32","data":"AAAA"}"#) }
        do {
            _ = try self.decode(#"{"shape":[-3],"scalarType":"int8","data":""}"#)
            Issue.record("expected a decoding error")
        } catch DecodingError.dataCorrupted(let context) {
            guard case .invalidTensor = context.underlyingError as? CoreAIRuntimeError else {
                Issue.record("expected an invalidTensor underlying error, got \(String(describing: context.underlyingError))")
                return
            }
        }
    }

    @Test
    func mutatedTensorsFailValidation() throws {
        var tensor = try CoreAITensor(float32: [1, 2], shape: [2])
        try tensor.validate()
        tensor.shape = [-2]
        #expect(throws: CoreAIRuntimeError.self) { try tensor.validate() }
        tensor.shape = [Int.max, 2]
        #expect(throws: CoreAIRuntimeError.self) { try tensor.validate() }
        tensor.shape = [2]
        tensor.scalarType = .float64
        #expect(throws: CoreAIRuntimeError.self) { try tensor.validate() }
        tensor.scalarType = .float32
        try tensor.validate()
    }
}
