import SwiftUI

struct AssistantDraftRow: View {
    let draft: AssistantDraft
    let busy: Bool
    let paired: Bool
    let save: (String, String) -> Bool
    let send: () -> Void
    let copy: () -> Void
    let remove: () -> Void
    @State private var editing = false
    @State private var title = ""
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.kind == .note ? "NOTE" : draft.kind == .taskDraft ? "TASK DRAFT" : "CLIENT UPDATE DRAFT")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(FlowStyle.muted)
                Spacer()
                Text(draft.atlasReference == nil ? "On this Mac" : "Saved to Atlas").font(.caption).foregroundStyle(FlowStyle.muted)
            }
            if editing {
                TextField("Draft title", text: $title).textFieldStyle(.roundedBorder)
                TextField("Draft text", text: $text, axis: .vertical).lineLimit(3...10).textFieldStyle(.roundedBorder)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Save changes") {
                        if save(title, text) { editing = false; error = nil }
                        else { error = "Use a title of 1–160 characters and text of 1–8,000 characters, and check local storage." }
                    }
                    Button("Cancel") { editing = false; error = nil }
                }
            } else {
                if draft.editedTitle != nil { Text(draft.title).font(.headline) }
                Text(draft.text).textSelection(.enabled)
                HStack {
                    if draft.atlasReference == nil {
                        Button(draft.submitted ? "Retry saving to Atlas" : "Save to Atlas", action: send).disabled(busy || !paired)
                    }
                    if !draft.submitted {
                        Button("Edit") { title = draft.title; text = draft.text; editing = true }.disabled(busy)
                    }
                    Button("Copy", action: copy)
                    Spacer()
                    Button("Remove local copy", role: .destructive, action: remove).disabled(busy)
                }
            }
        }.padding(18).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
