import Foundation

struct PreparedCoachRequest: Sendable {
    let model: String
    let prompt: String
    let inputMode: CoachInputMode
    let audio: AudioCoachInput?
    let body: Data

    init(rawText: String, model: String, prompt: String, inputMode: CoachInputMode, wave: Data?) throws {
        try Task.checkCancellation()
        self.model = model; self.prompt = prompt; self.inputMode = inputMode
        if inputMode == .originalAudio {
            guard let wave else { throw CoachFailure.missingAudio }
            audio = try AudioCoachInput(wave: wave)
        } else { audio = nil }
        let content: Any
        if let audio {
            content = [["type": "text", "text": rawText],
                       ["type": "input_audio", "input_audio": ["data": audio.wave.base64EncodedString(), "format": audio.format]]]
        } else { content = rawText }
        body = try JSONSerialization.data(withJSONObject: ["model": model, "stream": false, "messages": [
            ["role": "system", "content": prompt], ["role": "user", "content": content]
        ]], options: [.withoutEscapingSlashes])
        guard body.count <= AudioCoachInput.maximumRequestBytes else { throw CoachFailure.audioTooLarge }
        try Task.checkCancellation()
    }
}
