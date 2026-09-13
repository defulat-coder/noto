import SwiftUI
import AppKit

enum InputPurpose {
    case newContent, chat, edit
    var focusNotification: Notification.Name {
        switch self { case .newContent: return .focusComposer; case .chat: return .focusChat; case .edit: return .focusEditor }
    }
    var label: String {
        switch self { case .newContent: return "新建内容"; case .chat: return "继续对话"; case .edit: return "编辑记录内容" }
    }
}

struct Composer: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let purpose: InputPurpose
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var placeholder: String? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = InputTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        view.purpose = purpose
        view.onSubmit = onSubmit; view.onCancel = onCancel
        view.delegate = context.coordinator; view.isRichText = false; view.drawsBackground = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 16); view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        switch purpose {
        case .newContent: view.placeholder = "写下想法，⌘ 回车保存。"
        case .chat: view.placeholder = "继续聊…"
        case .edit: view.placeholder = "记录内容不能为空。"
        }
        if let placeholder { view.placeholder = placeholder }
        view.setAccessibilityLabel(purpose.label)
        context.coordinator.view = view
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: purpose.focusNotification, object: nil, queue: .main) { [weak view] _ in view?.window?.makeFirstResponder(view) }
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.scrollRangeToVisible(view.selectedRange())
        }
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? InputTextView else { return }
        context.coordinator.parent = self
        if view.string != text {
            view.string = text; view.undoManager?.removeAllActions()
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        view.onSubmit = onSubmit; view.onCancel = onCancel
        if view.isEditable != enabled { view.isEditable = enabled }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        let bounds = (text.isEmpty ? " " : text) as NSString
        let rect = bounds.boundingRect(with: NSSize(width: max(40, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 16)])
        return CGSize(width: width, height: min(purpose == .chat ? 120 : 160, max(32, ceil(rect.height) + 6)))
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: Composer
        weak var view: NSTextView?
        var observer: NSObjectProtocol?
        init(_ parent: Composer) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func textDidChange(_ notification: Notification) { parent.text = view?.string ?? ""; view?.needsDisplay = true }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
                parent.onCancel(); return true
            }
            return false // Return belongs to NSTextView, including input-method composition.
        }
    }
}

/// 通过 become/resignFirstResponder 跟踪焦点，避免监听每个 runloop tick 的 NSWindow.didUpdateNotification。
final class FocusSearchField: NSSearchField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}

struct SearchInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "搜索记录与对话"
    var focused: Binding<Bool> = .constant(false)
    /// 实时文本留在输入框内，延迟提交到 binding：避免每键触发整树重算（列表刷新本身另有 200ms 去抖）。
    var commitDelay: TimeInterval = 0
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let view = FocusSearchField()
        view.onFocusChange = { [weak coordinator = context.coordinator] active in
            coordinator?.parent.focused.wrappedValue = active
        }
        view.isEditable = true; view.isSelectable = true
        view.cell?.usesSingleLineMode = true; view.cell?.isScrollable = true
        view.isBezeled = false; view.drawsBackground = false
        view.sendsSearchStringImmediately = true
        view.sendsWholeSearchString = false
        view.controlSize = .regular
        view.placeholderString = placeholder; view.font = .systemFont(ofSize: 13)
        view.delegate = context.coordinator; view.setAccessibilityLabel("搜索")
        view.target = context.coordinator; view.action = #selector(Coordinator.searchChanged(_:))
        view.focusRingType = .none
        let hiddenSearchButton = NSButtonCell()
        hiddenSearchButton.title = ""; hiddenSearchButton.image = nil; hiddenSearchButton.isTransparent = true
        (view.cell as? NSSearchFieldCell)?.searchButtonCell = hiddenSearchButton
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .focusSearch, object: nil, queue: .main) { [weak view] _ in view?.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: NSSearchField, context: Context) {
        view.placeholderString = placeholder; context.coordinator.parent = self
        guard (view.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if view.stringValue != text {
            // 外部清空/覆盖（如 Esc、切换模式）立即生效，并丢弃未提交的去抖。
            context.coordinator.commitWork?.cancel(); context.coordinator.commitWork = nil
            view.stringValue = text
        }
    }
    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchInput
        var observer: NSObjectProtocol?
        var commitWork: DispatchWorkItem?
        init(_ parent: SearchInput) { self.parent = parent }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            commitWork?.cancel()
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused.wrappedValue = true }
        func controlTextDidEndEditing(_ notification: Notification) {
            commitWork?.cancel(); commitWork = nil
            parent.focused.wrappedValue = false
        }
        @objc func searchChanged(_ field: NSSearchField) {
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            commit(field)
        }
        private func commit(_ field: NSSearchField) {
            let delay = parent.commitDelay
            guard delay > 0 else {
                parent.text = field.stringValue
                if parent.text != field.stringValue { field.stringValue = parent.text }
                return
            }
            commitWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak field] in
                guard let self, let field else { return }
                self.parent.text = field.stringValue
            }
            commitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField { searchChanged(field) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText(),
                  let field = control as? NSSearchField else { return false }
            if !field.stringValue.isEmpty {
                // Esc 清空立即提交，保持「退出即恢复列表」的即时行为。
                commitWork?.cancel(); commitWork = nil
                field.stringValue = ""
                parent.text = ""
            }
            else { field.window?.makeFirstResponder(nil) }
            return true
        }
    }
}

class InputTextView: NSTextView {
    var purpose: InputPurpose = .newContent
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    func submit() { if isEditable && !hasMarkedText() { onSubmit?() } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 && flags.contains(.command) && !flags.contains(.shift) {
            submit(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 0, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}
