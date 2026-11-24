import SwiftUI
import JobsmithKit

/// "Flush inbox…": dump stale undecided Inbox jobs. The rules live in
/// `JobStore.flushInbox`; this sheet only picks the age filter and shows the
/// live count.
struct FlushInboxSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var limitByAge = true
    @State private var days = 14

    private var cutoff: Date? {
        guard limitByAge else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
    private var count: Int {
        (try? model.jobStore.flushableCount(olderThan: cutoff)) ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Only jobs found more than \(days) days ago", isOn: $limitByAge)
                    if limitByAge {
                        Stepper("\(days) days", value: $days, in: 1...365)
                    }
                } footer: {
                    Text("Removes Inbox jobs you haven't decided on. Jobs you shortlisted, passed, applied to, or started work on are kept. A flushed posting comes back if a later search still finds it. Syncs to your other devices.")
                }
                Section {
                    Button("Flush \(count) jobs", role: .destructive) {
                        model.flushInbox(olderThan: cutoff)
                        dismiss()
                    }
                    .disabled(count == 0)
                }
            }
            .navigationTitle("Flush inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
