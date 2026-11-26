import AppKit

struct OverlayStyle: Equatable {
    var fontSize = 23.0
    var position = 4.0
    var opacity = 0.45
    var lightBackground = false
    // Show lower-half caption translations in one fixed band instead of next to each line.
    var subtitleBand = true
}

@MainActor final class Overlay {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(wrappingLabelWithString: "")
    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 32, weight: .semibold)
        label.shadow = NSShadow()
        label.shadow?.shadowBlurRadius = 4
        label.shadow?.shadowColor = .black
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(label)
        panel.contentView = container
    }
    var style = OverlayStyle() { didSet { layout() } }
    private var anchor: CGRect?
    private var text = ""
    private var box = CGRect.zero
    private var above = false
    // `above` places the overlay over the box instead of below it, as the caption band does.
    func show(_ text: String, box: CGRect, above: Bool = false) {
        guard self.text != text || self.box != box || self.above != above else { return }
        self.box = box
        self.text = text
        self.above = above
        layout()
    }
    func move(to frame: CGRect?, level: NSWindow.Level) {
        guard frame != anchor || level != panel.level else { return }
        panel.level = level
        anchor = frame
        layout()
    }
    func hide() { panel.orderOut(nil); text = "" }
    private func layout() {
        guard !text.isEmpty, let frame = anchor, frame.width > 60, frame.height > 30 else {
            panel.orderOut(nil)
            return
        }
        label.stringValue = text
        label.font = .systemFont(ofSize: style.fontSize, weight: .semibold)
        label.textColor = style.lightBackground ? .black : .white
        let background: NSColor = style.lightBackground ? .white : .black
        panel.contentView?.layer?.backgroundColor = background.withAlphaComponent(style.opacity).cgColor
        let source = CGRect(x: frame.minX + box.minX * frame.width, y: frame.maxY - box.maxY * frame.height,
                            width: box.width * frame.width, height: box.height * frame.height)
        let natural = (text as NSString).size(withAttributes: [.font: label.font!]).width
        let width = min(frame.width, max(60, min(max(220, source.width * 1.45), natural + 40)))
        label.preferredMaxLayoutWidth = width - 40
        let height = min(frame.height, max(40, label.fittingSize.height + 18))
        let left = min(frame.maxX - width, max(frame.minX, source.midX - width / 2))
        let below = source.minY - height - style.position
        let over = min(frame.maxY - height, source.maxY + style.position)
        let bottom = above || below < frame.minY ? over : below
        panel.setFrame(NSRect(x: left, y: max(frame.minY, bottom), width: width, height: height), display: true)
        label.frame = NSRect(x: 20, y: 9, width: width - 40, height: height - 18)
        panel.orderFrontRegardless()
    }
}

import Carbon

@MainActor final class GlobalShortcut {
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var toggle: () -> Void = {}

    func install() -> Bool {
        if key != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ref = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4354524B, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().toggle() }
            return noErr
        }, 1, &type, ref, &handler)
        guard installed == noErr else { return false }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x4354524B, id: 1), GetApplicationEventTarget(), 0, &key)
        if result != noErr { remove(); return false }
        return true
    }

    func remove() {
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
        key = nil
        handler = nil
    }
}
