import Foundation

enum OpenAIAPIModelMetadataBaseline {
    static let baselineVersion = "2026-09-04"
    static let schemaVersion = 2

    static let json = """
    {
      "schema_version": 2,
      "models": [
        {
          "id": "gpt-6-astra",
          "display_name": "GPT-6 Astra",
          "protocols": ["responses"],
          "reasoning": {
            "modes": ["standard", "pro"],
            "efforts": ["low", "medium", "high", "xhigh", "max"]
          },
          "streaming": true,
          "tokens": {
            "context_window_tokens": 1050000,
            "max_output_tokens": 128000
          }
        }
      ],
      "disabled_model_ids": []
    }
    """

    static var data: Data {
        Data(json.utf8)
    }

    static func decode() throws -> OpenAIAPIModelMetadataDecodeReport {
        try OpenAIAPIModelMetadataDecoder.decodeWithReport(data)
    }
}
