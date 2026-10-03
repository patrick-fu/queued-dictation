import AppKit
import DictationCore

@MainActor
final class RecoveryActionsView: NSStackView {
    enum Action { case resumeUnsent, retryTranscription, retryPolish, retryCoach }
    private let onAction: (UUID, Action) throws -> Void
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let resume = NSButton(title: "继续未发送工作", target: nil, action: nil)
    private let transcription = NSButton(title: "显式重试转写", target: nil, action: nil)
    private let polish = NSButton(title: "显式重试润色", target: nil, action: nil)
    private let coach = NSButton(title: "显式重试带教", target: nil, action: nil)
    private var item: RecoveryItem?

    init(onAction: @escaping (UUID, Action) throws -> Void) {
        self.onAction = onAction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical; alignment = .leading; spacing = 8
        explanation.textColor = .secondaryLabelColor
        message.textColor = .systemRed
        for (button, action) in [(resume, #selector(resumeUnsent)), (transcription, #selector(retryTranscription)),
                                  (polish, #selector(retryPolish)), (coach, #selector(retryCoach))] {
            button.target = self; button.action = action
        }
        let buttons = NSStackView(views: [resume, transcription, polish, coach])
        buttons.spacing = 8
        addArrangedSubview(explanation)
        addArrangedSubview(buttons)
        addArrangedSubview(message)
        explanation.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        message.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        render(nil)
    }

    required init?(coder: NSCoder) { nil }

    func render(_ item: RecoveryItem?, terminating: Bool = false) {
        if self.item != item { message.stringValue = "" }
        self.item = item
        isHidden = item == nil
        resume.isEnabled = item?.canResumeUnsent == true && !terminating
        transcription.isEnabled = item?.needsTranscriptionRetry == true && !terminating
        polish.isEnabled = item?.needsPolishRetry == true && !terminating
        coach.isEnabled = item?.needsCoachRetry == true && !terminating
        guard let item else { explanation.stringValue = ""; return }
        var lines = ["恢复片段 \(item.id.uuidString.prefix(8))：已有文本请手动取用；重启后的旧输入目标无法确认。复制不会放行队列。"]
        if item.interruptedRecording { lines.append("中断录音仅找回可靠保存的音频部分，不保证尾部；可先下载检查，再决定是否处理。") }
        if item.canResumeUnsent { lines.append("继续只处理可证明未发送的工作，取最新配置并重开等待时间窗。") }
        if item.needsTranscriptionRetry || item.needsPolishRetry || item.needsCoachRetry {
            lines.append("显式重试会建立所选角色的新尝试；旧请求可能已发送，已有产物保留。")
        }
        if item.deliveryUncertain { lines.append("交付不确定：请先检查原目标，再从手动交付确认本段已粘贴；不能再次插入。") }
        explanation.stringValue = lines.joined(separator: "\n")
    }

    @objc private func resumeUnsent() { perform(.resumeUnsent, button: resume) }
    @objc private func retryTranscription() { perform(.retryTranscription, button: transcription) }
    @objc private func retryPolish() { perform(.retryPolish, button: polish) }
    @objc private func retryCoach() { perform(.retryCoach, button: coach) }

    private func perform(_ action: Action, button: NSButton) {
        guard button.isEnabled, let selected = item else { return }
        do {
            try onAction(selected.id, action)
            if item == selected { message.stringValue = "已提交本段操作。" }
        } catch {
            guard item == selected else { return }
            message.stringValue = (error as? DictationError)?.localizedDescription
                ?? (error as? TranscriptionFailure)?.localizedDescription ?? (error as? PolishFailure)?.localizedDescription
                ?? (error as? CoachFailure)?.localizedDescription ?? "恢复操作未完成，请检查配置、钥匙串访问与可用空间。"
        }
    }
}
