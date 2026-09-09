import SwiftUI
import AppKit
import NotoCore

extension NSPasteboard.PasteboardType {
    static let notoTask = NSPasteboard.PasteboardType("app.noto.task")
}

/// Native destinations own the whole column/day, including the empty drop area.
struct TaskDropArea<Content: View>: NSViewRepresentable {
    let onDrop: (Entry) -> Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> TaskDropHost {
        let view = TaskDropHost(rootView: AnyView(content()))
        view.registerForDraggedTypes([.notoTask])
        return view
    }
    func updateNSView(_ view: TaskDropHost, context: Context) {
        view.rootView = AnyView(content())
        view.onDrop = onDrop
    }
}

final class TaskDropHost: NSHostingView<AnyView> {
    var onDrop: (Entry) -> Bool = { _ in false }
    private func highlight(_ active: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = active ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
    }
    static func entry(from pasteboard: NSPasteboard) -> Entry? {
        guard pasteboard.pasteboardItems?.count == 1,
              let data = pasteboard.data(forType: .notoTask),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.kind == "todo" else { return nil }
        return entry
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = sender.draggingSource is TaskDragLabel && Self.entry(from: sender.draggingPasteboard) != nil
        highlight(valid)
        return valid ? .move : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { sender.draggingSource is TaskDragLabel && Self.entry(from: sender.draggingPasteboard) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        guard sender.draggingSource is TaskDragLabel, let entry = Self.entry(from: sender.draggingPasteboard) else { return false }
        return onDrop(entry)
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlight(false) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { highlight(false) }
}

/// A native label keeps click/keyboard activation and dragging in one event handler.
/// SwiftUI's focusable text can consume the mouse-down before its parent's drag recognizer.
struct TaskCardTitle: NSViewRepresentable {
    let entry: Entry
    var compact = false
    var lines = 4
    let onEdit: () -> Void
    func makeNSView(context: Context) -> TaskDragLabel {
        let button = TaskDragLabel()
        button.isBordered = false; button.alignment = .left
        button.isEditable = false; button.isSelectable = false; button.drawsBackground = false
        button.maximumNumberOfLines = compact ? 1 : lines; button.lineBreakMode = .byTruncatingTail
        button.cell?.wraps = !compact
        button.setAccessibilityRole(.button)
        return button
    }
    func updateNSView(_ button: TaskDragLabel, context: Context) {
        button.onEdit = onEdit
        guard button.entry != entry || button.compact != compact || button.lines != lines else { return }
        button.entry = entry; button.compact = compact; button.lines = lines; button.measuredSize = nil
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = compact ? 0 : 4; paragraph.lineBreakMode = compact ? .byTruncatingTail : .byWordWrapping
        button.attributedStringValue = NSAttributedString(string: entry.text, attributes: [
            .font: NSFont.systemFont(ofSize: compact ? 11 : 14), .foregroundColor: entry.completed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        button.payload = try? JSONEncoder().encode(entry)
        button.maximumNumberOfLines = compact ? 1 : lines
        button.onEdit = onEdit
        button.setAccessibilityLabel("编辑任务：\(entry.text)")
        button.toolTip = "点击编辑；拖动调整任务"
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TaskDragLabel, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 220)
        if let size = nsView.measuredSize, size.width == width { return size }
        let height = nsView.attributedStringValue.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let size = CGSize(width: width, height: min(compact ? 20 : CGFloat(lines * 20), max(20, ceil(height))))
        nsView.measuredSize = size
        return size
    }
}

final class TaskDragLabel: NSTextField, NSDraggingSource {
    var measuredSize: CGSize?
    var entry: Entry?
    var compact = false
    var lines = 4
    var payload: Data?
    var onEdit: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool { onEdit(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onEdit() } else { super.keyDown(with: event) }
    }
    private var dragStart: (event: NSEvent, payload: Data)?
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = payload.map { (event, $0) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { dragStart = nil; onEdit() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart,
              hypot(event.locationInWindow.x - start.event.locationInWindow.x,
                    event.locationInWindow.y - start.event.locationInWindow.y) >= 3 else { return }
        dragStart = nil
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(start.payload, forType: .notoTask)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = NSImage(size: bounds.size)
        image.lockFocus(); attributedStringValue.draw(in: bounds); image.unlockFocus()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
