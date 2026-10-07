import AppKit
import Foundation
import Testing
import DictationCore
@testable import RuntimeUI

@Suite(.serialized)
@MainActor
struct CoachSettingsSwitchTests {
    @Test
    func externalSwitchChangesPreserveOpenDraftsAndSavingOtherFieldsDoesNotReenableCoach() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-coach-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = CoachSettings(file: root.appendingPathComponent("coach.json"))
        let services = ServiceSettings(file: root.appendingPathComponent("services.json"))
        let serviceID = UUID()
        try services.save(ModelConfiguration(services: [.init(id: serviceID, name: "测试服务", baseURL: "http://127.0.0.1", authentication: .none)]))
        try settings.save(CoachConfiguration(enabled: true, role: .init(serviceID: serviceID, model: "old-model")))
        let scheduler = try CoachWorkScheduler(settings: settings, services: services, credentials: NoCredentials(), onUpdate: { _ in })
        defer { scheduler.stopProcessing() }
        let controller = CoachSettingsWindowController(scheduler: scheduler, settings: settings, services: services)
        defer { scheduler.onChange = nil; controller.window?.orderOut(nil) }
        scheduler.onChange = {
            let selector = NSSelectorFromString("synchronizeEnabled")
            if controller.responds(to: selector) { controller.perform(selector) }
        }
        let content = try #require(controller.window?.contentView)
        let views = descend(content)
        let buttons = views.compactMap { $0 as? NSButton }
        let enabled = try #require(buttons.first { $0.title == "开启英语带教和卡片浮窗" })
        let save = try #require(buttons.first { $0.title == "保存带教配置" })
        let fields = views.compactMap { $0 as? NSTextField }
        let model = try #require(fields.first { $0.placeholderString?.contains("模型 ID") == true })
        let concurrency = try #require(fields.first { $0.placeholderString == "1–10，默认 3" })
        let timeout = try #require(fields.first { $0.placeholderString == "5–600 秒，默认 30" })
        let prompt = try #require(views.compactMap { $0 as? NSTextView }.first)
        let pickers = views.compactMap { $0 as? NSPopUpButton }
        let inputMode = try #require(pickers.first { $0.itemTitles.first?.contains("文本（") == true })
        let corner = try #require(pickers.first { $0.itemTitles == ["右下", "左下", "右上", "左上"] })
        model.stringValue = "draft-audio-model"
        concurrency.stringValue = "7"
        timeout.stringValue = "45"
        prompt.string = "尚未保存的完整提示词。"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: prompt))
        inputMode.selectItem(at: 1); corner.selectItem(at: 2)
        #expect(controller.window?.isVisible == false)
        try scheduler.setEnabled(false)
        #expect(enabled.state == .off)
        #expect(model.stringValue == "draft-audio-model")
        #expect(concurrency.stringValue == "7")
        #expect(timeout.stringValue == "45")
        #expect(prompt.string == "尚未保存的完整提示词。")
        #expect(inputMode.indexOfSelectedItem == 1 && corner.indexOfSelectedItem == 2)
        save.performClick(nil)
        let saved = try settings.load()
        #expect(!saved.enabled && !scheduler.configuration.enabled)
        #expect(saved.role?.model == "draft-audio-model")
        #expect(saved.concurrency == 7 && saved.timeout == 45)
        #expect(saved.customPrompt == "尚未保存的完整提示词。")
        #expect(saved.inputMode == .originalAudio && saved.corner == .topRight)
        enabled.performClick(nil)
        #expect(try settings.load().enabled)
        #expect(scheduler.configuration.enabled)
        #expect(controller.window?.isVisible == false)
    }

    private func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
}

@MainActor
private struct NoCredentials: ServiceCredentialStoring {
    func key(for id: UUID) throws -> String? { nil }
    func saveKey(_ value: String?, for id: UUID) throws {}
    func deleteKey(for id: UUID) throws {}
}
