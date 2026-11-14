import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum SendOutcome { case failed, finished(ShareQueueResult) }

/// Keep the sheet open while guarded transfers run. Protected descriptors
/// survive extension termination; Imora can resume them with the same authority.
final class ShareViewController: UIViewController {
    private var providers: [NSItemProvider] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
        let host = UIHostingController(rootView: ShareSheetView(count: providers.count,
            signedIn: ShareTransfer.credentials() != nil,
            send: { [weak self] in await self?.send() ?? .failed }, complete: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func send() async -> SendOutcome {
        guard let credentials = ShareTransfer.credentials() else { return .failed }
        let capabilities = await ShareUploader.uploadCapabilities(credentials)
        var prepared: [ShareUploader.Prepared] = []
        var alreadyUploaded = 0, failures = 0
        for provider in providers {
            guard !Task.isCancelled else { break }
            switch await ShareUploader.prepare(provider, credentials: credentials, capabilities: capabilities) {
            case .upload(let item): prepared.append(item)
            case .done: alreadyUploaded += 1
            case .failed: failures += 1
            }
        }
        guard !Task.isCancelled, ShareTransfer.credentials()?.identity == credentials.identity else {
            for item in prepared { try? FileManager.default.removeItem(at: item.bodyURL) }
            return .failed
        }
        var result = await ShareUploader.handOff(prepared, credentials: credentials)
        result.uploaded += alreadyUploaded
        result.failed += failures
        return .finished(result)
    }

    private func finish() {
        ShareUploadActivity.shared.cancelPending()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private let brandTint = Color(red: 171 / 255, green: 115 / 255, blue: 242 / 255)

private struct ShareSheetView: View {
    let count: Int
    let signedIn: Bool
    let send: () async -> SendOutcome
    let complete: () -> Void
    private enum Phase: Equatable {
        case idle, sending, failed
        case done(uploaded: Int, failed: Int, pending: Int)
    }
    @State private var phase = Phase.idle
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: icon).font(.system(size: 52)).foregroundStyle(brandTint.gradient)
                Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
                footer
            }
            .padding(24).frame(maxWidth: 420).frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.25), value: phase)
            .navigationTitle("Imora").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { operation?.cancel(); complete() }
                        .accessibilityIdentifier("share-cancel")
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        ZStack {
            switch phase {
            case .idle where count > 0 && signedIn, .sending:
                Button(action: start) {
                    ZStack {
                        Text("Add to Imora").opacity(phase == .sending ? 0 : 1)
                        if phase == .sending { ProgressView() }
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(brandTint).controlSize(.large).disabled(phase == .sending)
                .accessibilityIdentifier("share-upload")
            case .done, .failed:
                Button("Done", action: complete).buttonStyle(.borderedProminent)
            default: Color.clear
            }
        }.frame(height: 52)
    }

    private func start() {
        guard phase == .idle else { return }
        phase = .sending
        operation = Task {
            switch await send() {
            case .failed: phase = .failed
            case .finished(let result):
                phase = .done(uploaded: result.uploaded, failed: result.failed, pending: result.pending)
                if result.failed == 0, result.pending == 0, !result.cancelled {
                    try? await Task.sleep(for: .milliseconds(900))
                    if !Task.isCancelled { complete() }
                }
            }
        }
    }
    private var icon: String {
        switch phase {
        case .done(_, let failed, let pending): return failed > 0 ? "exclamationmark.triangle" : (pending > 0 ? "pause.circle" : "checkmark.circle.fill")
        case .failed: return "exclamationmark.triangle"
        default: break
        }
        if count == 0 { return "photo.badge.exclamationmark" }
        if !signedIn { return "person.crop.circle.badge.questionmark" }
        return "icloud.and.arrow.up"
    }
    private var title: String {
        switch phase {
        case .done(_, let failed, let pending): return failed > 0 ? String(localized: "Sharing needs attention") : (pending > 0 ? String(localized: "Ready to resume") : String(localized: "Shared to Imora"))
        case .failed: return String(localized: "Could not complete sharing")
        case .sending: return String(localized: "Uploading to Imora")
        case .idle: break
        }
        if count == 0 { return String(localized: "Nothing to add") }
        if !signedIn { return String(localized: "Sign in first") }
        return count == 1 ? String(localized: "Add 1 item") : String(localized: "Add \(count) items")
    }
    private var subtitle: String {
        switch phase {
        case .done(let uploaded, let failed, let pending):
            if failed > 0 { return String(localized: "Confirmed \(uploaded) items on your server. \(failed) items could not be confirmed. Open Imora to review pending shares, or share them again.") }
            if pending > 0 { return String(localized: "Confirmed \(uploaded) items. Open Imora to finish \(pending) pending shares.") }
            return String(localized: "The server confirmed these files.")
        case .failed: return String(localized: "These files could not be confirmed on your server. Open Imora or share them again.")
        case .sending: return String(localized: "Keep this sheet open until sharing finishes. System interruptions can pause it; open Imora to resume. Files already sent stay on the server.")
        case .idle: break
        }
        if count == 0 { return String(localized: "Nothing here that Imora can upload.") }
        if !signedIn { return String(localized: "Open Imora and connect to your server, then share again.") }
        return String(localized: "Files go directly to your configured server. Keep this sheet open during the transfer.")
    }
}
