import SwiftUI
import QuickLook
import JobsmithKit

/// Review and edit the tailored resume and cover letter; AI Edit revises
/// with natural-language instructions; approve locks it for applying.
struct DocumentReviewView: View {
    @Environment(AppModel.self) private var model
    let jobId: String

    enum Doc: String, CaseIterable { case resume = "Resume", coverLetter = "Cover letter" }

    @State private var application: Application?
    @State private var job: Job?
    @State private var selected: Doc = .resume
    @State private var resumeText = ""
    @State private var coverText = ""
    @State private var showAIEdit = false
    @State private var revising = false
    @State private var previewURL: URL?
    /// "Check this" — names, numbers and credentials the profile, posting and
    /// facts don't back. A warning only; it never blocks saving or applying.
    @State private var flags = FactGuard.DocumentFlags()
    @State private var checkLevel: HonestyConfig.Level = .honest
    /// Instructions typed in AI Edit count as sources, like on the desktop.
    @State private var typedInstructions: [String] = []

    var body: some View {
        Group {
            if application != nil {
                editor
            } else {
                ContentUnavailableView("Nothing to review yet", systemImage: "doc.text",
                                       description: Text("Tailor this job first to generate documents."))
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            Picker("Document", selection: $selected) {
                ForEach(Doc.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            factNotice

            TextEditor(text: selected == .resume ? $resumeText : $coverText)
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 12)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.03))

            HStack(spacing: 10) {
                Button {
                    showAIEdit = true
                } label: {
                    Label("AI Edit", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(revising)

                Button {
                    preview()
                } label: {
                    Label("Preview", systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    saveAndRegenerate()
                } label: {
                    Label("Save & Regenerate", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ember)
            }
            .padding(16)
        }
        .overlay {
            if revising {
                ProgressView("Revising…")
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.thickMaterial))
            }
        }
        .sheet(isPresented: $showAIEdit) {
            if let application {
                AIEditSheet(applicationId: application.id) { instructions, honesty, tier in
                    await revise(instructions: instructions, honesty: honesty, tier: tier)
                }
            }
        }
        .onChange(of: selected) { _, _ in recheck() }
        .quickLookPreview($previewURL)
        .onDisappear(perform: saveEdits)
    }

    private func load() {
        job = try? model.jobStore.job(id: jobId)
        application = try? model.applicationStore.application(jobId: jobId)
        resumeText = application?.resumeContent ?? ""
        coverText = application?.coverLetterContent ?? ""
        checkLevel = application.flatMap { HonestyConfig.Level(rawValue: $0.honestyLevel) }
            ?? model.config.honesty.level
        recheck()
    }

    /// The "Check this: …" line for the document on screen (nothing when clean,
    /// and nothing at the embellished and fabricated levels).
    @ViewBuilder private var factNotice: some View {
        if let notice = FactGuard.notice(selected == .resume ? flags.resume : flags.coverLetter) {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Theme.emberDeep)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityLabel(notice)
        }
    }

    private func recheck() {
        guard let application else { return }
        let facts = (try? model.applicationFactStore.texts(applicationId: application.id)) ?? []
        flags = FactGuard.checkDocuments(
            resume: resumeText, coverLetter: coverText, profile: model.config.profile,
            job: job, honesty: checkLevel, appFacts: facts, extra: typedInstructions)
    }

    private func saveEdits() {
        guard let application else { return }
        try? model.applicationStore.updateContent(id: application.id,
                                                  resume: resumeText, coverLetter: coverText)
        recheck()
    }

    private func preview() {
        guard let application, let job else { return }
        saveEdits()
        var updated = application
        updated.resumeContent = resumeText
        updated.coverLetterContent = coverText
        try? model.regenerateDocuments(for: updated, job: job)
        let kind: FileVault.Kind = selected == .resume ? .resume : .coverLetter
        previewURL = FileVault.url(jobId: job.id, kind: kind,
                                   format: model.config.honesty.documentFormat)
    }

    private func saveAndRegenerate() {
        guard let application, let job else { return }
        saveEdits()
        var updated = application
        updated.resumeContent = resumeText
        updated.coverLetterContent = coverText
        try? model.regenerateDocuments(for: updated, job: job)
        model.refresh()
    }

    private func revise(instructions: String, honesty: HonestyConfig.Level, tier: ModelTier) async {
        guard let job, let application else { return }
        revising = true
        defer { revising = false }
        // Read at call time: facts may have been added in the sheet just now.
        let appFacts = (try? model.applicationFactStore.texts(applicationId: application.id)) ?? []
        do {
            if selected == .resume {
                resumeText = try await TailoringService.reviseResume(
                    currentResume: resumeText, instructions: instructions, job: job,
                    profile: model.config.profile, config: model.config,
                    engine: model.aiEngine, tier: tier, honestyLevel: honesty,
                    appFacts: appFacts)
            } else {
                coverText = try await TailoringService.reviseCoverLetter(
                    currentLetter: coverText, instructions: instructions, job: job,
                    profile: model.config.profile, config: model.config,
                    engine: model.aiEngine, tier: tier, honestyLevel: honesty,
                    appFacts: appFacts)
            }
            // The check follows the level this edit ran at, and what the user
            // just asked for counts as a source.
            checkLevel = honesty
            typedInstructions.append(instructions)
            saveEdits()
        } catch {
            model.lastError = "AI Edit failed: \(error.localizedDescription)"
        }
    }
}

struct AIEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let applicationId: String
    let onSubmit: (String, HonestyConfig.Level, ModelTier) async -> Void

    @State private var instructions = ""
    @State private var honesty: HonestyConfig.Level = .honest
    @State private var tier: ModelTier = .strong
    @State private var facts: [ApplicationFact] = []
    @State private var factError: String?
    @State private var justKept = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Emphasize my Kubernetes experience and shorten the summary",
                              text: $instructions, axis: .vertical)
                        .lineLimit(3...8)
                    Button {
                        keepInstruction()
                    } label: {
                        Label(justKept ? "Kept for future edits" : "Keep this for future edits",
                              systemImage: justKept ? "checkmark" : "pin")
                    }
                    .disabled(instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let factError {
                        Text(factError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Eyebrow(text: "What should change?")
                } footer: {
                    Text("Keep saves this instruction as a fact for this application, so every later edit remembers it.")
                }
                Section {
                    Picker("Honesty", selection: $honesty) {
                        ForEach(HonestyConfig.Level.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    Picker("Model", selection: $tier) {
                        Text("Strong").tag(ModelTier.strong)
                        Text("Fast").tag(ModelTier.fast)
                    }
                } header: {
                    Eyebrow(text: "This edit only")
                }
                FactsListSection(
                    header: "Facts for this application",
                    footer: "Short true statements the AI keeps in mind for every edit of this resume and cover letter. "
                        + "Up to \(CandidateFacts.maxFacts), \(CandidateFacts.maxFactChars) characters each.",
                    rows: facts.compactMap { fact in
                        fact.id.map { FactRow(id: Int($0), text: fact.text) }
                    },
                    onAdd: { text in
                        try model.applicationFactStore.add(applicationId: applicationId, text: text)
                        reloadFacts()
                    },
                    onEdit: { id, text in
                        try model.applicationFactStore.update(id: Int64(id), text: text)
                        reloadFacts()
                    },
                    onRemove: { id in
                        try? model.applicationFactStore.delete(id: Int64(id))
                        reloadFacts()
                    })
            }
            .navigationTitle("AI Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Revise") {
                        let text = instructions
                        let level = honesty
                        let modelTier = tier
                        dismiss()
                        Task { await onSubmit(text, level, modelTier) }
                    }
                    .disabled(instructions.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            honesty = model.config.honesty.level
            tier = model.config.honesty.aiEditTier
            reloadFacts()
        }
        .onChange(of: instructions) { _, _ in justKept = false }
        .presentationDetents([.medium, .large])
    }

    private func reloadFacts() {
        facts = (try? model.applicationFactStore.facts(applicationId: applicationId)) ?? []
    }

    /// Save the instruction as a fact for this application.
    private func keepInstruction() {
        do {
            try model.applicationFactStore.add(applicationId: applicationId, text: instructions)
            factError = nil
            justKept = true
            reloadFacts()
        } catch {
            factError = error.localizedDescription
        }
    }
}
