import SwiftUI
import JobsmithKit

/// One fact in a list. `id` is whatever the owner needs to find it again (an
/// array offset for the profile list, the row id for an application's).
struct FactRow: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// The add / edit / remove list shared by "Facts about me" (Profile) and
/// "Facts for this application" (AI Edit). Limits come from `CandidateFacts`
/// (50 per list, 1000 characters each), the same as the desktop.
struct FactsListSection: View {
    let header: String
    let footer: String
    let rows: [FactRow]
    let onAdd: (String) throws -> Void
    let onEdit: (Int, String) throws -> Void
    let onRemove: (Int) -> Void

    @State private var adding = false
    @State private var editing: FactRow?

    var body: some View {
        Section {
            ForEach(rows) { row in
                Button {
                    editing = row
                } label: {
                    Text(row.text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { rows[$0].id }
                for id in ids.sorted(by: >) { onRemove(id) }
            }
            if rows.count < CandidateFacts.maxFacts {
                Button {
                    adding = true
                } label: {
                    Label("Add a fact", systemImage: "plus")
                }
            }
        } header: {
            Eyebrow(text: header)
        } footer: {
            Text(footer)
        }
        .sheet(isPresented: $adding) {
            FactTextSheet(title: "New fact", initial: "") { try onAdd($0) }
        }
        .sheet(item: $editing) { row in
            FactTextSheet(title: "Edit fact", initial: row.text) { try onEdit(row.id, $0) }
        }
    }
}

/// Edit one fact's text, with the same limits the desktop enforces.
struct FactTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: (String) throws -> Void
    @State private var text: String
    @State private var errorText: String?

    init(title: String, initial: String, onSave: @escaping (String) throws -> Void) {
        self.title = title
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .font(.callout)
                } header: {
                    Eyebrow(text: "A short true statement")
                } footer: {
                    Text("\(text.unicodeScalars.count) / \(CandidateFacts.maxFactChars)")
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try onSave(text)
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Facts about me": profile-wide facts, edited on the profile's own copy so
/// they save with the rest of the profile.
struct ProfileFactsView: View {
    @Binding var facts: [String]

    var body: some View {
        Form {
            FactsListSection(
                header: "Facts about me",
                footer: "Short true statements the AI can rely on in every resume, cover letter, AI edit and written answer — for example \"Speaks at regional meetups\" or \"Prefers small teams\". "
                    + "Up to \(CandidateFacts.maxFacts), \(CandidateFacts.maxFactChars) characters each. Kept on this device.",
                rows: facts.enumerated().map { FactRow(id: $0.offset, text: $0.element) },
                onAdd: { text in
                    try CandidateFacts.checkNewCount(facts.count)
                    facts.append(try CandidateFacts.clean(text))
                },
                onEdit: { index, text in
                    guard facts.indices.contains(index) else { return }
                    facts[index] = try CandidateFacts.clean(text)
                },
                onRemove: { index in
                    if facts.indices.contains(index) { facts.remove(at: index) }
                })
        }
        .navigationTitle("Facts about me")
        .navigationBarTitleDisplayMode(.inline)
    }
}
