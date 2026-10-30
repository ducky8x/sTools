import AppKit
import SwiftUI

/// Keeps the AppKit view behind a plain SwiftUI `TextField` at least one line tall.
///
/// Now and then SwiftUI sizes that view to another font's line (17 pt for a 14 pt field's 20 pt line). AppKit cuts a
/// field's glyphs off at the bottom of its view, so a short view loses the descenders of g, y and p in everything the
/// field draws itself: text too long for it, right-to-left text, and fields that have no overlay, such as the number
/// and slider value fields. Placed as a background, this finds the field SwiftUI laid out in the same slot and, each
/// time its view comes out shorter than `minimumHeight`, makes it that tall again with its top edge where it was. The
/// view SwiftUI wraps the field in grows with it. Nothing else in the layout moves: the guard draws nothing and takes
/// no clicks, and a slot that holds no field is left alone.
struct STFieldLineGuard: NSViewRepresentable {
    let minimumHeight: CGFloat

    func makeNSView(context: Context) -> GuardView { GuardView() }

    func updateNSView(_ view: GuardView, context: Context) {
        view.minimumHeight = minimumHeight
        view.attach()
    }

    @MainActor
    final class GuardView: NSView {
        var minimumHeight: CGFloat = 0
        private weak var field: NSTextField?
        private weak var wrapper: NSView?
        private var observers: [any NSObjectProtocol] = []
        private var isRestoring = false
        private var searchIsScheduled = false
        /// How many more times a search that finds no field is tried again, a turn of the run loop apart.
        private var searchesLeft = 4

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// The field being kept tall, once found. Tests read it.
        var watchedField: NSTextField? { field }

        /// A background takes no clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if field == nil { searchesLeft = 4 }
            attach()
        }

        override func layout() {
            super.layout()
            attach()
        }

        /// Starts watching the field in this view's slot once there is one, and keeps it tall enough. SwiftUI adds this
        /// view and the field in one pass, in no set order, so a search that finds no field tries again on later turns.
        func attach() {
            if let field, field.superview == nil {
                stopWatching()
                searchesLeft = 4
            }
            if field == nil, searchesLeft > 0 {
                if let found = neighbor() {
                    watch(found)
                } else {
                    searchesLeft -= 1
                    scheduleSearch()
                }
            }
            restore()
        }

        /// Tries again on the run loop's next turn. A run loop block, not a dispatch one: a test that spins the run loop
        /// from inside a main-queue job never runs the main queue's blocks.
        private func scheduleSearch() {
            guard !searchIsScheduled else { return }
            searchIsScheduled = true
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.searchIsScheduled = false
                    self.attach()
                }
            }
        }

        private func watch(_ found: NSTextField) {
            field = found
            wrapper = found.superview.flatMap { $0.subviews.count == 1 ? $0 : nil }
            found.postsFrameChangedNotifications = true
            wrapper?.postsFrameChangedNotifications = true
            observers = [found, wrapper].compactMap { $0 }.map { view in
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.restore() }
                }
            }
        }

        private func stopWatching() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            field = nil
            wrapper = nil
        }

        /// The editable text field SwiftUI laid out in the slot this view fills: the one whose frame lies mostly inside it.
        private func neighbor() -> NSTextField? {
            guard let slotView = superview, let container = slotView.superview else { return nil }
            let slot = slotView.frame
            var best: (field: NSTextField, area: CGFloat)?
            func visit(_ view: NSView) {
                for child in view.subviews where child !== slotView {
                    guard let candidate = child as? NSTextField, candidate.isEditable else {
                        visit(child)
                        continue
                    }
                    let frame = container.convert(candidate.bounds, from: candidate)
                    let overlap = frame.intersection(slot)
                    let area = overlap.isNull ? 0 : overlap.width * overlap.height
                    if area > 0, area >= frame.width * frame.height / 2, area > (best?.area ?? 0) {
                        best = (candidate, area)
                    }
                }
            }
            visit(container)
            return best?.field
        }

        /// Makes the field, and the view wrapped around it, at least `minimumHeight` tall, tops where they were.
        private func restore() {
            guard let field, minimumHeight > 0, !isRestoring else { return }
            isRestoring = true
            defer { isRestoring = false }
            guard let wrapper else {
                if field.frame.height < minimumHeight - 0.01 { resize(field, toHeight: minimumHeight) }
                return
            }
            // The gap between the wrapper's top and the field's top, before either changes.
            let gap = wrapper.isFlipped ? field.frame.minY : wrapper.bounds.height - field.frame.maxY
            if wrapper.bounds.height < gap + minimumHeight - 0.01 { resize(wrapper, toHeight: gap + minimumHeight) }
            if field.frame.height < minimumHeight - 0.01 {
                let y = wrapper.isFlipped ? gap : wrapper.bounds.height - gap - minimumHeight
                field.frame = NSRect(x: field.frame.minX, y: y, width: field.frame.width, height: minimumHeight)
            }
        }

        /// Sets `view`'s height, its top edge staying where it is in its superview.
        private func resize(_ view: NSView, toHeight height: CGFloat) {
            var frame = view.frame
            let delta = height - frame.height
            frame.size.height = height
            if let parent = view.superview, !parent.isFlipped { frame.origin.y -= delta }
            view.frame = frame
        }
    }
}
