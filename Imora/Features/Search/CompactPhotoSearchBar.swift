import SwiftUI
import UIKit

struct CompactPhotoSearchBar: View {
    struct FocusRequest: Equatable {
        private let id = UUID()
        let focused: Bool
    }

    @Binding var query: String
    let prompt: String
    let focus: FocusRequest
    let onSubmit: () -> Void
    let onClose: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                SearchField(query: $query, prompt: prompt, focus: focus, onSubmit: onSubmit)
                    .padding(.horizontal, 8)
                    .frame(height: 46)
                    .glassEffect(.regular, in: .capsule)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 46, height: 46)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

private struct SearchField: UIViewRepresentable {
    @Binding var query: String
    let prompt: String
    let focus: CompactPhotoSearchBar.FocusRequest
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.accessibilityIdentifier = "photos-search-field"
        field.accessibilityTraits.insert(.searchField)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.clearButtonMode = .whileEditing
        let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)))
        magnifier.frame = CGRect(x: 0, y: 0, width: 28, height: 32)
        magnifier.contentMode = .center
        magnifier.tintColor = .label
        field.leftView = magnifier
        field.leftViewMode = .always
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = true
        field.writingToolsBehavior = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.text != query, field.markedTextRange == nil { field.text = query }
        field.placeholder = prompt
        field.focus = focus
    }

    static func dismantleUIView(_ field: Field, coordinator: Coordinator) {
        field.focus = nil
        field.resignFirstResponder()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Field: UITextField {
        var focus: CompactPhotoSearchBar.FocusRequest? {
            didSet { if oldValue != focus { applyFocus() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyFocus()
        }

        private func applyFocus() {
            guard window != nil, let focus else { return }
            if focus.focused {
                if !isFirstResponder, !becomeFirstResponder() {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.window != nil, self.focus == focus, !self.isFirstResponder else { return }
                        self.becomeFirstResponder()
                    }
                }
            } else if isFirstResponder {
                resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchField

        init(parent: SearchField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            parent.query = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.query = field.text ?? ""
            field.resignFirstResponder()
            parent.onSubmit()
            return false
        }
    }
}
