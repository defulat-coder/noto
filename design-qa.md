# Noto — native design QA

## 双击交互交付（2026-09-09）

当前交互以 [双击录入、AI 与原位编辑验收](design/DOUBLE-CLICK-QA.md) 为准：回车统一换行，⌘ 回车按输入用途提交。以下为历史记录，常驻输入、回车发送和编辑弹窗描述均已替代。

## 全项目设计交付（2026-09-08 晚）

最新规范与本轮验收见 [设计规范](design/DESIGN-SYSTEM.md)、[目标交付](design/DELIVERY.md)、[完整 QA](design/REDESIGN-QA.md)。以下是此前的历史验证；新的反馈位置、输入组件、对话响应式和动效规则以本轮文档为准。

## Panel motion (2026-09-08)

Implemented 280ms smooth transitions for date-rail expansion and conversation opening/closing, including surrounding content and search layout. The right pane slides and fades as one unit with its divider. New messages use a 200ms fade with an 8pt offset; active-date changes use 160ms easing. Explicit motion is disabled when accessibilityReduceMotion is enabled. Release build passed. Native playback verification is pending: CUA reported that the Mac is locked and automatic unlock failed. Earlier visual passes below do not establish animation quality for this update.

## Native typography and interaction polish (2026-09-08)

Existing screen inspected first: `design/native-polish-before.jpg`. Final: `design/native-polish-after.jpg`; combined review: `design/native-polish-comparison.jpg`. Both native captures are 1106 × 768. The final fixture additionally contains the todo used to check the native checkbox.

Body text is now 15pt system text, input 16pt, metadata 11–13pt, with reduced line spacing. A wider reading column avoids excessive wrapping when chat is open. The composer has a restrained rounded input boundary. Search is NSSearchField with native focus and clear behavior; todos use native checkbox toggles. Edit controls remain discoverable and no longer replace timestamps on hover. Selected dates use the system accent. The conversation uses native material and semantic colors; the forced light appearance was removed. No top toolbar was restored.

Native checks passed: ⌘K and immediate search, native clear button restoring results, checkbox persistence and undo feedback, Escape closing chat with focus returning to notes, and reopening the same chat restoring unsent text. Draft retention is in-memory for pane switching, not a promise of unsent-draft persistence across app termination. ⌘N now also scrolls to the composer. Release build passed. Full VoiceOver, every window size and dark-mode visual inspection were not performed in this pass. No outstanding P0/P1/P2 issue found in the checked flows.

## Remove top chrome (2026-09-08)

Removed the native toolbar, its title, background and separator. The full-size content view extends behind a transparent hidden-title window. Sidebar and search controls are plain overlays; search stays within the notes pane when conversation is open. Native window controls and background dragging remain available. Release build passed; native inspection confirmed no horizontal white toolbar, no overlap with conversation controls, and working ⌘K search. Evidence: `design/no-titlebar.jpg`. This supersedes toolbar descriptions in earlier checks.

## Persistent conversation and execution disclosure (2026-09-08)

Result: passed for the requested scope. `design/chat-comparison.jpg` compares the existing date-rail visual language with the new right conversation pane, collapsed and expanded. Native captures are 1106 × 768. This is a scoped addition to the existing screen, not a replacement design; the populated fixtures differ because the new evidence is a real CLI conversation.

- ⌘ Return opens the right pane and saves only the original question as the note's visible text. The pane keeps the same neutral colors, restrained typography and hairlines. Inline Markdown formatting is rendered; the input height was reduced after the first visual check.
- Three real OpenCode turns produced six saved messages under one note. A follow-up correctly recalled the preceding suggestion, and a third request shortened it. One initial follow-up returned prose instead of action JSON; conversational prose is now accepted as display-only output, while invalid action JSON still fails without writes.
- Reopening the test app restored the original question; its conversation button restored history and allowed continuation. Native ⌘ Return and Return sent follow-ups. Native search for `nickname`, found only in a later turn, returned the original question. CLI search for the assistant-only phrase `和光同尘` returned the same note.
- Each new turn offers a native DisclosureGroup, initially off. The tested third turn expanded to real context counts, OpenCode launch, return/validation and saved completion at 8 seconds. It could be collapsed; reopening the pane reset it to collapsed. Execution text is persisted and included in the complete CLI export. Earlier turns predate this addition and have no invented execution details.
- SQLite export independently verified one original-question entry, six ordered messages and execution details. All four tests passed, including persisted multi-turn search, atomic reply/action rollback, duplicate-reply rejection and execution persistence. Release build passed.
- Evidence: `design/chat-execution-collapsed.jpg`, `design/chat-execution-expanded.jpg`. No outstanding P0/P1/P2 issue found in this scoped check. Replies appear after CLI completion; token streaming and private model reasoning are not part of this implementation. Codex and Claude local limitations documented below remain; their multi-turn success is not claimed.

## Date navigation update (2026-09-08)

Result: passed for the requested scope. The user's follow-up adds a collapsed date rail and an optional expanded sidebar, superseding the original no-sidebar layout below.

Reference: `design/date-anchor-reference.png`. Combined visual review: `design/date-anchors-comparison.jpg`. Final native captures: `design/date-anchors-collapsed.jpg` and `design/date-anchors-expanded.jpg`, both 1106 × 768, same September 3 content position. The reference supplies only the small tick navigation pattern; its surrounding Codex interface is not a layout target. Dates and the expanded state are explicit user additions. The earlier `date-anchors-collapsed.png` is superseded by the JPG.

- Default: an 88-point rail with short ticks and compact dates; no panel background. The active date uses darker ink. Expanded: 180-point date list, subtle background and selected row, toggled by the toolbar's native sidebar icon. Existing single-column typography and restrained separators remain.
- Native interaction checks used an isolated SQLite fixture with 110 records across 55 days. Initial navigation exposed the first page; scrolling loaded older dates through July 15. Date clicks scrolled to the matching content. Expanding preserved the September 3 position. A database search found the 50th day's record. At the very bottom, scrolling is clamped to the content end; the highlighted date reflects the top visible day.
- Fixed an initial defect where identical rail/content IDs caused the scroll reader to target the wrong scroll view. Content IDs now have their own prefix. The final captures show the requested September 3 content at the top in both states.
- Release build passed. All three unit tests passed, including a 105-record pagination test for ordering, no duplicates/skips after concurrent insertion, search, and invalid limits.
- No outstanding P0/P1/P2 issue found in this scope. Full VoiceOver and every window size remain outside this check.

final result: passed

Source visual truth: `design/reference.png` (the first displayed image in the latest ideation set, selected by the user).
Implementation: `design/implementation-final.png`.
Full-view comparison: `design/comparison.png` (source left, native implementation right).
Focused evidence: `design/comparison-detail.png`; the same reading column is also legible in the full comparison.

## Viewport and state

Source 1487 × 1058 pixels. Native preview requested 1340 × 954 points and was fit to the available display. CUA screenshot is 1085 × 768 pixels. Both images were scaled proportionally to 1086 pixels wide for comparison, without stretching (source height 773, implementation height 769). Native pixels and source pixels are not assumed to have equal display density. No CSS viewport applies: this is a SwiftUI/AppKit app.

State: populated preview with the selected input sentence, one note, one open todo, completion feedback and undo. Preview data lives in memory. Timestamp is real local preview creation time instead of the mock's 14:20. Due label says 明天 instead of 明天下午 because this version implements calendar due dates, not timed reminders. Inactive native titlebar buttons are gray; this is macOS window state, not a token mismatch.

## Comparison history and findings

- Initial native capture (`design/implementation-initial.png`) exposed duplicate title text and a denser/wider column at the smaller window size. The automatic window title was hidden, column width became responsive with the source's 44.5% proportion and slight right offset, and preview sizing was aligned with source aspect ratio.
- Native interaction testing exposed a toolbar focus problem for ⌘K. Replaced the search text field bridge with an NSTextField that accepts first responder; verified shortcut followed by text entry filters results.
- Preview ordering and undo availability were corrected to match the selected source state.
- Final combined comparison (`design/comparison.png`): no outstanding P0/P1/P2 issues. The one-input/one-list hierarchy, column placement, whitespace, subtle rules and action placement match the selected direction.

## Required fidelity surfaces

- Typography: native SF/PingFang system text, 18pt input, 17pt records, 13–14pt secondary text. Native font shaping replaces rasterized generated letters. Comfortable wrapping and editable multiline input; no decorative headings were introduced.
- Layout: one centered/slightly offset narrow content column, no sidebar/panels. Input underline, keyboard hint, date grouping, note/todo rows and restrained feedback are present. A few pixels of vertical rhythm difference remain as P3 refinement.
- Color: near-white canvas, dark graphite content, muted secondary text, hairline separators. No extra accents, gradients or cards. Toolbar material follows the current macOS native appearance.
- Assets: no raster artwork was needed. Native SF Symbols are used for arrows, checkboxes, search and editing. Wordmark is editable text as in the source.
- Content: source sample sentence and note preserved. Temporal text deviations are listed above. Empty, search-empty, busy, failure and undo states are implemented without adding permanent UI.
- Settings: revised per the user's latest instruction to only AI CLI picker and Done. OpenCode is the default; no CLI selector or provider label in the main interface.

## Functional evidence

- Real native UI: enter to save, ⌘K to search, checkbox completion, undo, ⌘N to refocus, settings picker.
- Isolated persistent GUI: CLI-created note appeared in the window; ⌘ Return invoked OpenCode, which generated a dated todo. CLI export independently confirmed persisted data. UI undo removed only the AI-created todo and retained the externally added note.
- Unit/CLI validation: atomic rollback, idempotency, undo conflict handling, independent store connections, invalid JSON rejection; CLI add/search/complete/filter/export.
- Real AI adapters: OpenCode complete GUI-to-CLI-to-database cycle and Kimi structured response passed. Codex's installed CLI is too old for its configured model. Claude invocation timed out. These environmental limits are disclosed in README; no success is simulated.
- No browser console applies to this native app. Builds and native UI observations were used; build success was not used as a substitute for visual review.

## Follow-up polish / limits

P3: macOS's current toolbar material differs slightly from the generated flat titlebar. Tiny vertical spacing differences can be tuned after user feedback. Exhaustive accessibility/VoiceOver testing, every window size, multi-monitor layouts, multi-turn agent sessions, timed reminders, and ChatGPT cloud/MCP connectivity are outside this first local version.
