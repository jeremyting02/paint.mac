import AppKit

// AppKit owns text entry, selection, key bindings and marked text. The canvas
// draws the text and its editing controls in image coordinates.
final class CanvasTextInput: NSTextView {
    var finish: (() -> Void)?
    var nudgeHandle: ((NSEvent) -> Bool)?
    var screenRect: ((Int) -> CGRect)?
    var indexAtScreenPoint: ((CGPoint) -> Int)?
    private let inputStorage: NSTextStorage

    init() {
        inputStorage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: 1_000_000, height: 1_000_000))
        inputStorage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: container)
        isRichText = false
        importsGraphics = false
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        setAccessibilityLabel("Canvas text")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func scrollRangeToVisible(_ range: NSRange) {}

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) }
        else { finish?() }
    }

    override func keyDown(with event: NSEvent) {
        if nudgeHandle?(event) == true { return }
        if event.keyCode == 53 && !hasMarkedText() {
            if !event.isARepeat { finish?() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let screenRect else { return super.firstRect(forCharacterRange: range, actualRange: actualRange) }
        let index = min(range.location, (string as NSString).length)
        actualRange?.pointee = NSRange(location: index, length: 0)
        return screenRect(index)
    }

    override func characterIndex(for point: NSPoint) -> Int {
        indexAtScreenPoint?(point) ?? super.characterIndex(for: point)
    }
}
