import Foundation
import NotoCore

// AI 对话：会话开合、发送、Agent 执行与执行过程记录。
extension AppModel {
    func ask() {
        guard !busy, composerPosition != nil, let store else { return }
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        do {
            if let conversation { chatDrafts[conversation.id] = chatDraft }
            newConversationOpen = false
            conversation = try store.startConversation(input)
            aiUsesCurrentView = false
            messages = try store.messages(for: conversation!.id)
            draft = ""; composerPosition = nil; readingRequested = false; chatDraft = ""; chatError = ""; message = ""; reload()
            requestReply()
        } catch { fail(error) }
    }
    func openQuickConversation() {
        guard leaveUnchangedEditor() else { return }
        composerPosition = nil; readingRequested = false
        if conversation == nil && !newConversationOpen {
            newConversationOpen = true; messages = []; chatDraft = newConversationDraft
            chatError = ""; aiUsesCurrentView = false
        }
        NotificationCenter.default.post(name: .focusChat, object: nil)
    }

    func openConversation(_ entry: Entry) {
        guard !busy, leaveUnchangedEditor() else { return }
        do {
            if newConversationOpen { newConversationDraft = chatDraft }
            newConversationOpen = false
            messages = try store?.messages(for: entry.id) ?? []
            if let conversation { chatDrafts[conversation.id] = chatDraft }
            if conversation?.id != entry.id { aiUsesCurrentView = false }
            conversation = entry; chatDraft = chatDrafts[entry.id] ?? ""; chatError = ""
            composerPosition = nil; readingRequested = false
        } catch { fail(error) }
    }
    func closeConversation() {
        guard !busy else { return }
        if let conversation { chatDrafts[conversation.id] = chatDraft }
        if newConversationOpen { newConversationDraft = chatDraft }
        newConversationOpen = false; conversation = nil
        readingRequested = true
    }
    func sendChat() {
        guard !busy, messages.last?.role != "user", let store else { return }
        if newConversationOpen {
            guard !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                let entry = try store.startConversation(chatDraft)
                conversation = entry; messages = try store.messages(for: entry.id)
                chatDraft = ""; newConversationDraft = ""; newConversationOpen = false
                reload(); requestReply()
            } catch { chatError = error.localizedDescription }
            return
        }
        guard let conversation else { return }
        do {
            try store.appendQuestion(chatDraft, to: conversation.id)
            chatDraft = ""; messages = try store.messages(for: conversation.id)
            requestReply()
        } catch { chatError = error.localizedDescription }
    }
    func replyContext() throws -> [Entry] {
        guard let store, let conversation,
              let current = try store.entry(id: conversation.id) else { throw NotoError("这条记录已不存在，请返回记录列表。") }
        self.conversation = current
        if aiUsesCurrentView { return filtered.map { $0.id == current.id ? current : $0 } }
        return [current]
    }
    func requestReply() {
        guard !busy, let store, let question = messages.last, question.role == "user" else { return }
        let context: [Entry]
        do { context = try replyContext() }
        catch { chatError = error.localizedDescription; return }
        let history = Array(messages.dropLast())
        let selectedProvider = provider
        let active = AgentRunner(); runner = active
        busy = true; activeProvider = selectedProvider; chatError = ""
        let startedAt = Date()
        recordExecution("已读取 \(history.count) 条历史消息与 \(context.count) 条记录", for: question)
        Task {
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try active.run(prompt: question.text, entries: context, provider: selectedProvider, history: history,
                                   workspaceURL: AgentWorkspace.directory(database: store.storageURL, conversationID: question.entryID)) { event in
                        Task { @MainActor in self.recordExecution(event, for: question) }
                    }
                }.value
                let changed = try store.apply(response.actions, expected: context, replyingTo: question, reply: response.message)
                if let updated = changed.first(where: { $0.id == conversation?.id }) { conversation = updated }
                if !changed.isEmpty { remember(before: context, after: changed, message: "已更新记录。") }
                messages = try store.messages(for: question.entryID)
                recordExecution("已保存回复\(changed.isEmpty ? "" : "，更新 \(changed.count) 条记录") · \(Int(Date().timeIntervalSince(startedAt))) 秒", for: question)
                reload()
            } catch {
                chatError = error.localizedDescription
                recordExecution("未完成：\(error.localizedDescription)", for: question)
            }
            busy = false; activeProvider = nil; runner = nil
        }
    }
    func recordExecution(_ event: String, for question: ChatMessage) {
        do {
            let previous = messages.first(where: { $0.id == question.id })?.execution ?? ""
            try store?.setExecution(previous.isEmpty ? event : previous + "\n" + event, for: question)
            messages = try store?.messages(for: question.entryID) ?? messages
        } catch { chatError = "执行过程保存失败：\(error.localizedDescription)" }
    }
    func cancel() { runner?.cancel() }
}
