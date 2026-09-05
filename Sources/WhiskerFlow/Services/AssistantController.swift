import AppKit
import Foundation
import Observation
import OpenTelemetryApi
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct AssistantDraft: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: AssistantRecordKind
    var text: String
    var editedTitle: String?
    var clientReference: String?
    var createdAt = Date()
    var atlasReference: String?
    var submitted = false
    var accountIdentity: String?
    var title: String { editedTitle ?? String(text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?.prefix(160) ?? "Voice note".prefix(160)) }
}

@MainActor @Observable
final class AssistantController {
    struct SavedState: Codable {
        var accountIdentity: String?
        var cloudEnabled = false
        var recognizeCorrections = true
        var profiles: [WritingProfile] = []
        var clients: [AssistantClientProfile] = []
        var clientVocabulary: [String: Vocabulary] = [:]
        var clientCustomVocabulary: [String: Vocabulary]?
        var clientUpdatedAt: [String: Date]?
        var selectedClient: String?
        var drafts: [AssistantDraft] = []
        var pendingJob: PendingJob?
    }
    struct PendingJob: Codable {
        var accountIdentity: String?
        var operation: String
        var arguments: Data
        var reference: String?
    }
    private(set) var saved = SavedState()
    var message: String?
    var busy = false
    private var pauseRequested = false
    var rewriteInput = ""
    var rewritePreview = ""
    var coachResult: AssistantCoachResult?
    var selection: TextFieldSnapshot?
    private var pendingSelection: TextFieldSnapshot?
    var capturePurpose: CapturePurpose = .dictation
    enum CapturePurpose: String, CaseIterable { case dictation = "Dictate", selectionInstruction = "Edit selection", quickCapture = "Quick capture" }
    var quickCaptureKind: AssistantRecordKind = .note
    var accountIdentityProvider: (() -> String?)?
    var requestTransport: (() throws -> any AssistantAtlasTransport)?
    private let fileURL: URL?
    private var loadFailed = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 8_388_608 else { throw AssistantError.message("Assistant data is too large.") }
            saved = try JSONDecoder().decode(SavedState.self, from: data)
        } catch { loadFailed = true; message = "Assistant data could not be opened. The original file has been kept." }
    }
    static func defaultStore() -> AssistantController {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AssistantController(fileURL: root.appendingPathComponent("WhiskerFlow/Assistant/assistant.json"))
    }
    @discardableResult
    private func update(_ edit: (inout SavedState) -> Void) -> Bool {
        guard !loadFailed else { return false }
        var next = saved
        edit(&next)
        do {
            let encoded = try JSONEncoder().encode(next)
            guard encoded.count <= 8_388_608 else { message = "Assistant storage is full. Remove an old local draft before saving more."; return false }
            if let fileURL {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try encoded.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            saved = next
            return true
        } catch { message = "Could not save locally. Free some disk space and try again."; return false }
    }
    @discardableResult
    func synchronizeAccount() -> Bool {
        guard let accountIdentityProvider else { return true }
        let identity = accountIdentityProvider()
        guard saved.accountIdentity != identity else { return true }
        let persisted = update { state in
            state.accountIdentity = identity
            state.clients = []; state.clientVocabulary = [:]; state.selectedClient = nil
            state.clientCustomVocabulary = [:]; state.clientUpdatedAt = [:]
            state.pendingJob = nil; state.cloudEnabled = false
        }
        selection = nil; pendingSelection = nil; rewriteInput = ""; rewritePreview = ""; coachResult = nil
        return persisted
    }
    func setCloudEnabled(_ value: Bool) { update { $0.cloudEnabled = value } }
    func setRecognizeCorrections(_ value: Bool) { update { $0.recognizeCorrections = value } }
    func selectClient(_ reference: String?) { update { $0.selectedClient = reference } }
    func setProfile(bundleIdentifier: String, style: WritingStyle) {
        guard !bundleIdentifier.isEmpty, bundleIdentifier.count <= 200 else { return }
        update { state in
            state.profiles.removeAll { $0.bundleIdentifier == bundleIdentifier }
            if style != .standard, state.profiles.count < 200 { state.profiles.append(.init(bundleIdentifier: bundleIdentifier, style: style)) }
        }
    }
    func style(for bundleIdentifier: String?) -> WritingStyle {
        saved.profiles.first { $0.bundleIdentifier == bundleIdentifier }?.style ?? .standard
    }
    var vocabulary: Vocabulary {
        guard let client = saved.selectedClient else { return Vocabulary() }
        return Vocabulary.effective(shared: saved.clientVocabulary[client] ?? Vocabulary(), personal: saved.clientCustomVocabulary?[client] ?? Vocabulary())
    }
    func addClientTerm(find: String, replacement: String) {
        guard let client = saved.selectedClient, !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, find.utf16.count <= 200, replacement.utf16.count <= 200 else { return }
        update { state in
            var vocabulary = state.clientCustomVocabulary?[client] ?? Vocabulary()
            vocabulary.rules.removeAll { $0.find == find }
            guard vocabulary.rules.count < 500 else { return }
            vocabulary.rules.append(.init(find: find, replaceWith: replacement))
            if state.clientCustomVocabulary == nil { state.clientCustomVocabulary = [:] }
            state.clientCustomVocabulary?[client] = vocabulary
        }
    }
    func removeClientTerm(_ id: UUID) {
        guard let client = saved.selectedClient else { return }
        update { $0.clientCustomVocabulary?[client]?.rules.removeAll { $0.id == id } }
    }
    @discardableResult
    func editDraft(_ id: UUID, title: String, text: String) -> Bool {
        guard let draft = saved.drafts.first(where: { $0.id == id }), !draft.submitted, draft.atlasReference == nil,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 160,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 8_000 else { return false }
        return update { state in
            guard let index = state.drafts.firstIndex(where: { $0.id == id }) else { return }
            state.drafts[index].editedTitle = title; state.drafts[index].text = text
        }
    }

    @discardableResult
    func captureSelection() -> Bool {
        guard !busy, saved.pendingJob == nil else { message = "Finish or discard the pending request before capturing another selection."; return false }
        clearSelection()
        guard let context = TextFieldSnapshot.capture(requireSelection: true) else {
            message = "Select up to 8,000 characters in another app, then use Capture selection. Some apps do not expose selected text."; return false
        }
        selection = context
        rewriteInput = context.selectedText
        rewritePreview = ""
        message = "Selection captured from \(context.application.localizedName ?? "another app")."
        return true
    }
    func clearSelection() { selection = nil; rewriteInput = ""; rewritePreview = "" }

    @discardableResult
    func saveLocalDraft(_ text: String, kind: AssistantRecordKind) -> UUID? {
        guard synchronizeAccount() else { return nil }
        return saveLocalDraft(text, kind: kind, clientReference: saved.selectedClient, accountIdentity: saved.accountIdentity)
    }
    @discardableResult
    func saveLocalDraft(_ text: String, kind: AssistantRecordKind, clientReference: String?, accountIdentity: String?) -> UUID? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 8_000 else {
            message = "A draft needs 1–8,000 characters. The original recording remains in History."; return nil
        }
        guard saved.drafts.count < 500 else { message = "Remove an old draft before adding another."; return nil }
        let draft = AssistantDraft(kind: kind, text: text, clientReference: clientReference, accountIdentity: accountIdentity)
        guard update({ $0.drafts.insert(draft, at: 0) }) else { return nil }
        message = "Saved on this Mac. Review it before saving to Atlas."
        return draft.id
    }
    func deleteLocalDraft(_ id: UUID) { update { $0.drafts.removeAll { $0.id == id } } }
    func sendDraft(_ id: UUID) async {
        guard !busy, let draft = saved.drafts.first(where: { $0.id == id }), draft.atlasReference == nil else { return }
        guard synchronizeAccount() else { return }
        guard draft.accountIdentity == nil || draft.accountIdentity == saved.accountIdentity else {
            message = "This draft belongs to a different Atlas connection. Reconnect that account or copy it for review."; return
        }
        guard saved.accountIdentity != nil || accountIdentityProvider == nil else { message = "Connect Atlas before saving this draft."; return }
        // Freeze the payload before a potentially ambiguous network result.
        guard update({ state in if let index = state.drafts.firstIndex(where: { $0.id == id }) { state.drafts[index].submitted = true; state.drafts[index].accountIdentity = state.accountIdentity } }) else { return }
        busy = true; defer { busy = false }
        do {
            var args: [String: Any] = ["requestId": draft.id.uuidString, "kind": draft.kind.rawValue, "title": draft.title, "text": draft.text]
            if let client = draft.clientReference { args["clientReference"] = client }
            let row = try await call("captureDraft", args)
            guard let reference = row["draftReference"] as? String else { throw AssistantError.message("Atlas returned an invalid draft receipt.") }
            guard update({ state in if let index = state.drafts.firstIndex(where: { $0.id == id }) { state.drafts[index].atlasReference = reference } }) else { return }
            message = "Saved as a private Atlas draft."
        } catch { message = error.localizedDescription }
    }
    func refreshClients() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            var profiles: [AssistantClientProfile] = []; var cursor: String?
            repeat {
                var args: [String: Any] = ["limit": 50]; if let cursor { args["cursor"] = cursor }
                let row = try await call("listClientProfiles", args)
                guard let data = row["profiles"] else { throw AssistantError.message("Atlas returned invalid client profiles.") }
                profiles += try JSONDecoder().decode([AssistantClientProfile].self, from: JSONSerialization.data(withJSONObject: data))
                cursor = row["nextCursor"] as? String
            } while cursor != nil && profiles.count < 500
            update { $0.clients = Array(profiles.prefix(500)) }
            if let client = saved.selectedClient { try await refreshVocabulary(client) }
            message = "Client profiles refreshed."
        } catch { message = error.localizedDescription }
    }
    func refreshSelectedVocabulary() async {
        guard !busy, let client = saved.selectedClient else { return }; busy = true; defer { busy = false }
        do { try await refreshVocabulary(client); message = "Client vocabulary is ready." } catch { message = error.localizedDescription }
    }
    private func refreshVocabulary(_ reference: String) async throws {
        let row = try await call("getClientProfile", ["clientReference": reference])
        guard let rules = row["rules"] as? [[String: String]], rules.count <= 500 else { throw AssistantError.message("Atlas returned invalid vocabulary.") }
        let vocabulary = Vocabulary(rules: rules.compactMap { row in
            guard let find = row["find"], let replacement = row["replaceWith"] else { return nil }
            return VocabularyRule(find: find, replaceWith: replacement)
        })
        update { state in
            state.clientVocabulary[reference] = vocabulary
            if state.clientUpdatedAt == nil { state.clientUpdatedAt = [:] }
            state.clientUpdatedAt?[reference] = Date()
        }
    }
    func rewrite(operation: String, instruction: String = "") async {
        guard !busy, rewriteInput.utf16.count <= 8_000, !rewriteInput.isEmpty, instruction.utf16.count <= 500 else {
            message = "Select 1–8,000 characters and keep instructions under 500 characters."; return
        }
        var args: [String: Any] = ["requestId": UUID().uuidString, "operation": operation, "text": rewriteInput]
        if operation == "custom" { guard !instruction.isEmpty else { return }; args["instruction"] = instruction }
        if let reference = saved.selectedClient { args["clientReference"] = reference }
        rewritePreview = ""
        await beginJob("rewrite", args)
    }
    func requestCoach(phase: String, goal: String, agenda: String = "", meetingReference: String? = nil) async {
        guard !busy, goal.utf16.count <= 500, agenda.utf16.count <= 4_000 else { message = "Keep the goal under 500 characters and agenda under 4,000."; return }
        guard synchronizeAccount() else { return }
        if phase == "premeeting", !saved.cloudEnabled {
            let outcome = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            let agendaText = agenda.trimmingCharacters(in: .whitespacesAndNewlines)
            coachResult = .init(kind: "coach", phase: phase, title: "Your meeting plan", suggestions: [
                .init(text: outcome.isEmpty ? "Agree the outcome you want before discussing options." : "Open by agreeing the outcome: \(outcome)", evidence: []),
                .init(text: agendaText.isEmpty ? "Choose the two or three questions that need an answer today." : "Use your agenda to keep the discussion focused: \(agendaText)", evidence: []),
                .init(text: "Leave time to confirm decisions, owners and the next check-in.", evidence: [])
            ], incomplete: false)
            message = "Prepared on this Mac from your goal and agenda."
            return
        }
        var args: [String: Any] = ["requestId": UUID().uuidString, "phase": phase, "goal": goal]
        if !agenda.isEmpty { args["agenda"] = agenda }
        if let meetingReference { args["meetingReference"] = meetingReference }
        if let reference = saved.selectedClient { args["clientReference"] = reference }
        coachResult = nil
        await beginJob("requestCoach", args)
    }
    private func beginJob(_ operation: String, _ args: [String: Any]) async {
        guard synchronizeAccount() else { return }
        guard saved.cloudEnabled else { message = "Enable Atlas AI to send this request. Local features work without it."; return }
        guard saved.pendingJob == nil else { message = "Resume or discard the pending request first."; return }
        do {
            let arguments = try JSONSerialization.data(withJSONObject: args)
            guard update({ $0.pendingJob = .init(accountIdentity: saved.accountIdentity, operation: operation, arguments: arguments) }) else { return }
            pendingSelection = operation == "rewrite" ? selection : nil
            await resumeJob()
        } catch { message = error.localizedDescription }
    }
    func pauseWaiting() { pauseRequested = true }
    func discardPendingJob() { guard !busy else { return }; update { $0.pendingJob = nil }; pendingSelection = nil; message = "Pending request removed from this Mac." }
    func resumeJob() async {
        guard !busy else { return }
        guard synchronizeAccount() else { return }
        guard saved.cloudEnabled, var job = saved.pendingJob,
              job.accountIdentity == saved.accountIdentity else { return }
        busy = true; pauseRequested = false; defer { busy = false }
        do {
            if job.reference == nil {
                let args = try JSONSerialization.jsonObject(with: job.arguments) as? [String: Any] ?? [:]
                let row = try await call(job.operation, args)
                guard let reference = row["jobReference"] as? String else { throw AssistantError.message("Atlas returned an invalid job receipt.") }
                job.reference = reference
                guard update({ $0.pendingJob = job }) else { return }
            }
            for _ in 0..<90 {
                if pauseRequested { message = "Waiting paused. Atlas may finish the request; resume when ready."; return }
                try Task.checkCancellation()
                let row = try await call("getResult", ["jobReference": job.reference!])
                switch row["status"] as? String {
                case "ready":
                    guard let result = row["result"] as? [String: Any] else { throw AssistantError.message("Atlas returned an empty result.") }
                    if result["kind"] as? String == "rewrite" {
                        guard let text = result["text"] as? String, !text.isEmpty, text.utf16.count <= 8_000 else { throw AssistantError.message("Atlas returned an invalid edit.") }
                        let source = try JSONSerialization.jsonObject(with: job.arguments) as? [String: Any]
                        rewriteInput = source?["text"] as? String ?? ""
                        selection = pendingSelection
                        rewritePreview = text
                    } else {
                        let result = try JSONDecoder().decode(AssistantCoachResult.self, from: JSONSerialization.data(withJSONObject: result))
                        guard result.kind == "coach", result.suggestions.count <= 5 else { throw AssistantError.message("Atlas returned an invalid review.") }
                        coachResult = result
                    }
                    update { $0.pendingJob = nil }; message = "Ready to review."; return
                case "failed", "expired":
                    update { $0.pendingJob = nil }; throw AssistantError.message("Atlas could not finish this request. You can try a new request.")
                case "queued", "processing": break
                default: throw AssistantError.message("Atlas returned an unknown job status.")
                }
                try await Task.sleep(for: .seconds(1))
            }
            message = "Atlas is still working. Resume this request later."
        } catch { message = error is CancellationError ? "Request paused. Resume when ready." : error.localizedDescription }
    }
    func call(_ operation: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard synchronizeAccount() else { throw AssistantError.message("Atlas connection state could not be saved. No request was sent.") }
        guard let requestTransport else { throw AssistantError.message("Connect Atlas in Meeting setup first.") }
        let account = saved.accountIdentity
        var versioned = args; versioned["contractVersion"] = 1
        return try await Observability.tracer.spanBuilder(spanName: "assistant.request").withActiveSpan { span in
            let category = ["captureDraft", "listClientProfiles", "getClientProfile", "rewrite", "getResult", "requestCoach", "addBookmark", "deleteCoach"].contains(operation) ? operation : "other"
            span.setAttribute(key: "assistant.operation", value: category)
            var outcome = "failure"
            defer {
                span.setAttribute(key: "outcome", value: outcome)
                Observability.assistantOperations.add(value: 1, attributes: ["operation": .string(category), "outcome": .string(outcome)])
            }
            do {
                guard accountIdentityProvider == nil || accountIdentityProvider?() == account else {
                    throw AssistantError.message("Atlas connection changed before sending. Please try again.")
                }
                let data = try await requestTransport().call(operation: operation, arguments: JSONSerialization.data(withJSONObject: versioned))
                guard accountIdentityProvider == nil || accountIdentityProvider?() == account else {
                    synchronizeAccount(); throw AssistantError.message("Atlas connection changed. The previous response was discarded.")
                }
                guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], row["contractVersion"] as? Int == 1 else { throw AssistantError.message("Atlas's assistant version is not supported by this app.") }
                outcome = "success"; span.status = .ok
                return row
            } catch {
                span.status = .error(description: "Assistant request failed")
                throw error
            }
        }
    }
}
