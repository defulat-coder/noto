import ArgumentParser
import Foundation
import NotoCore

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Output structured JSON (also the default).") var json = false
    @Option(help: "Override the SQLite database path; defaults to Noto's shared local database.") var database: String?
    func store() throws -> Store { try Store(url: database.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Store.defaultURL) }
}

@main
struct Noto: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "noto", abstract: "Local notes and todos, for people and agents.", version: "0.1.0", subcommands: [Note.self, Todo.self, Search.self, Export.self, Conversation.self, Doctor.self, Ask.self])
}
struct Note: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read and write notes.", subcommands: [AddNote.self, ListNotes.self, UpdateNote.self])
}
struct Todo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage todos.", subcommands: [AddTodo.self, ListTodos.self, Complete.self, Reopen.self, UpdateTodo.self])
}
struct AddNote: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add")
    @OptionGroup var output: OutputOptions
    @Option var text: String
    @Option(help: "Idempotency key; reuse for retries of the same creation.") var requestId: String?
    func run() throws { try printJSON(output.store().add(kind: "note", text: text, requestID: requestId)) }
}
struct AddTodo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add")
    @OptionGroup var output: OutputOptions
    @Option var title: String
    @Option(help: "Due date YYYY-MM-DD (does not schedule a timed notification).") var due: String?
    @Option var requestId: String?
    func run() throws { try printJSON(output.store().add(kind: "todo", text: title, due: due, requestID: requestId)) }
}
struct ListNotes: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var output: OutputOptions
    func run() throws { try printJSON(output.store().list().filter { $0.kind == "note" }) }
}
struct ListTodos: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var output: OutputOptions
    @Option(help: "all, open or completed") var status = "all"
    func validate() throws { guard ["all", "open", "completed"].contains(status) else { throw ValidationError("status must be all, open or completed") } }
    func run() throws { try printJSON(output.store().list().filter { $0.kind == "todo" && (status == "all" || $0.completed == (status == "completed")) }) }
}
struct Complete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "complete")
    @OptionGroup var output: OutputOptions
    @Option var id: String
    func run() throws { try printJSON(output.store().setCompleted(id: id, completed: true)) }
}
struct Reopen: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reopen")
    @OptionGroup var output: OutputOptions
    @Option var id: String
    func run() throws { try printJSON(output.store().setCompleted(id: id, completed: false)) }
}
struct UpdateNote: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update")
    @OptionGroup var output: OutputOptions
    @Option var id: String
    @Option var text: String
    func run() throws {
        let store = try output.store()
        guard try store.list().contains(where: { $0.id == id && $0.kind == "note" }) else { throw ValidationError("note id not found") }
        try printJSON(store.update(id: id, text: text, due: nil))
    }
}
struct UpdateTodo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update")
    @OptionGroup var output: OutputOptions
    @Option var id: String
    @Option var title: String?
    @Option var due: String?
    @Flag var clearDue = false
    func validate() throws { if clearDue && due != nil { throw ValidationError("Use either --due or --clear-due") } }
    func run() throws {
        let store = try output.store()
        guard let entry = try store.list().first(where: { $0.id == id && $0.kind == "todo" }) else { throw ValidationError("todo id not found") }
        try printJSON(store.update(id: id, text: title ?? entry.text, due: clearDue ? nil : (due ?? entry.due)))
    }
}
struct Search: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @Argument var query: String
    func run() throws { try printJSON(output.store().page(limit: Int.max - 1, search: query).entries) }
}
struct Conversation: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read the full conversation attached to a note.")
    @OptionGroup var output: OutputOptions
    @Option var id: String
    func run() throws { try printJSON(output.store().messages(for: id)) }
}
struct Export: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @Flag var includeConversations = false
    func run() throws {
        let store = try output.store(), entries = try store.list()
        if includeConversations {
            struct Backup: Encodable { let entries: [Entry]; let conversations: [String: [ChatMessage]] }
            var conversations: [String: [ChatMessage]] = [:]
            for entry in entries where entry.hasConversation { conversations[entry.id] = try store.messages(for: entry.id) }
            try printJSON(Backup(entries: entries, conversations: conversations))
        } else { try printJSON(entries) }
    }
}
struct Doctor: ParsableCommand {
    func run() throws { try printJSON(Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0.rawValue, $0.locate() ?? "not found") })) }
}
struct Ask: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Ask an installed AI CLI to propose actions. Writes only with --apply.")
    @OptionGroup var output: OutputOptions
    @Argument var prompt: String
    @Option var provider = "codex"
    @Flag var apply = false
    func run() throws {
        guard let selected = Provider(rawValue: provider) else { throw ValidationError("Unknown provider") }
        let store = try output.store()
        let context = try store.list()
        let response = try AgentRunner().run(prompt: prompt, entries: context, provider: selected)
        if apply { _ = try store.apply(response.actions, expected: context) }
        try printJSON(response)
    }
}
