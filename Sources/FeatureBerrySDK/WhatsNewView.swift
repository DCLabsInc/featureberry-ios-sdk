#if canImport(UIKit) && canImport(SwiftUI) && canImport(StoreKit)
import SwiftUI
import UIKit
import StoreKit
import os

private let whatsNewLogger = Logger(subsystem: "com.featureberry.sdk", category: "WhatsNew")

@MainActor
public extension FeatureBerry {
    /// Checks the current app version and presents the SDK's What's New flow when needed.
    /// Configure feature flags first and call again when the app is ready if presentation fails.
    static func CheckWhatsNew(releaseCodeword: String) {
        guard !isPresentingWhatsNew else { return }
        let infoDictionary = Bundle.main.infoDictionary
        let alwaysShow = shouldAlwaysShowWhatsNew(from: infoDictionary)
        guard let version = whatsNewVersion(from: infoDictionary) ?? (alwaysShow ? "always" : nil) else {
            whatsNewLogger.error("Cannot check What's New: the app bundle has no version.")
            return
        }
        guard shouldCheckWhatsNew(
            currentVersion: version,
            lastVersion: UserDefaults.standard.string(forKey: whatsNewPresentationKey),
            alwaysShow: alwaysShow
        ) else { return }
        guard let configured = client else {
            whatsNewLogger.error("Cannot check What's New: FeatureBerry is not configured.")
            return
        }
        guard !releaseCodeword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            whatsNewLogger.error("Cannot check What's New: the release codeword is empty.")
            return
        }

        isPresentingWhatsNew = true
        let api = WhatsNewClient(
            apiKey: configured.apiKey, appShortName: configured.appShortName, baseURL: configured.baseURL)
        Task { @MainActor in
            defer { isPresentingWhatsNew = false }
            do {
                let release = try await api.fetchRelease(codeword: releaseCodeword)
                guard !release.visibleFeatures.isEmpty else {
                    UserDefaults.standard.set(version, forKey: whatsNewPresentationKey)
                    return
                }
                guard let presenter = await whatsNewPresenter() else {
                    whatsNewLogger.error("Cannot present What's New: no unambiguous active presenter is ready. Call again when the app is ready.")
                    return
                }
                let controller = UIHostingController(rootView: WhatsNewView(
                    release: release, client: api,
                    scene: presenter.view.window?.windowScene,
                    onPresented: { UserDefaults.standard.set(version, forKey: whatsNewPresentationKey) }))
                controller.modalPresentationStyle = .pageSheet
                if let sheet = controller.sheetPresentationController {
                    sheet.detents = [.large()]
                    sheet.prefersGrabberVisible = true
                }
                presenter.present(controller, animated: true)
                for _ in 0..<20 {
                    if UserDefaults.standard.string(forKey: whatsNewPresentationKey) == version {
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                whatsNewLogger.error("What's New did not appear; call again when presentation is available.")
            } catch {
                whatsNewLogger.error("What's New check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func whatsNewPresenter() async -> UIViewController? {
        for attempt in 0...20 {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            if scenes.count == 1,
               let window = scenes[0].windows.first(where: { $0.isKeyWindow }),
               let root = window.rootViewController,
               root.viewIfLoaded?.window === window,
               root.presentedViewController == nil,
               !root.isBeingDismissed,
               !root.isBeingPresented {
                return root
            }
            if attempt < 20 {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return nil
    }
}

@MainActor
private struct WhatsNewView: View {
    let release: WhatsNewRelease
    let client: WhatsNewClient
    let scene: UIWindowScene?
    let onPresented: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showReviews = false
    @State private var testingEnabled = FeatureBerry.userIsTesting

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(release.releaseName).font(.title2.bold())
                    featureSection("New features", status: "Shipped")
                    Divider()
                    featureSection("Now testing", status: "Testing")
                    if release.features.contains(where: { $0.status == "Testing" }) {
                        Toggle("Show test features", isOn: $testingEnabled)
                            .onChange(of: testingEnabled) { _, value in
                                FeatureBerry.userIsTesting = value
                            }
                            .tint(.pink)
                    }
                    #if canImport(ReplayKit)
                    if testingEnabled,
                       let codeword = release.codeword,
                       FeatureBerrySessionManager.shared.isConfiguredForRelease(codeword: codeword) {
                        FeatureBerrySessionButton(title: "Perform test session")
                    }
                    #endif
                    Button("Continue") { showReviews = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                        .frame(maxWidth: .infinity)
                    Text("Powered by 🍓FeatureBerry")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(isPresented: $showReviews) {
                ShowcasedReviewsView(client: client, scene: scene, onClose: { dismiss() })
            }
        }
        .onAppear(perform: onPresented)
        .onReceive(NotificationCenter.default.publisher(for: FeatureBerry.userIsTestingChangedNotification)) { _ in
            testingEnabled = FeatureBerry.userIsTesting
        }
    }

    @ViewBuilder
    private func featureSection(_ title: String, status: String) -> some View {
        let features = release.features.filter { $0.status == status }
        if !features.isEmpty {
            Text(title).font(.headline)
            ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title).font(.headline)
                    if !feature.description.isEmpty {
                        Text(feature.description).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

@MainActor
private struct ShowcasedReviewsView: View {
    let client: WhatsNewClient
    let scene: UIWindowScene?
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reviews: [ShowcasedReview] = []
    @State private var error: String?
    @State private var isLoading = true
    @State private var selectedReview: Int?

    var body: some View {
        VStack(spacing: 24) {
            if isLoading {
                ProgressView()
            } else if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Try again") { Task { await loadReviews() } }
            } else if reviews.isEmpty {
                Text("No showcased reviews yet.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(reviews) { review in
                            reviewCard(review).id(review.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $selectedReview)
                .scrollTargetBehavior(.viewAligned)
                .task(id: reduceMotion) {
                    guard !reduceMotion, reviews.count > 1 else { return }
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) }
                        catch { return }
                        let index = reviews.firstIndex { $0.id == selectedReview } ?? 0
                        withAnimation { selectedReview = reviews[(index + 1) % reviews.count].id }
                    }
                }
            }
            Button("Submit review") {
                guard let scene else {
                    whatsNewLogger.error("Cannot request an App Store review: no window scene.")
                    return
                }
                SKStoreReviewController.requestReview(in: scene)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close", action: onClose)
            }
        }
        .task { await loadReviews() }
    }

    private func loadReviews() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            reviews = try await client.fetchReviews()
            selectedReview = reviews.first?.id
        } catch {
            whatsNewLogger.error("Unable to load showcased reviews: \(error.localizedDescription, privacy: .public)")
            self.error = "Unable to load reviews. Please try again."
        }
    }

    private func reviewCard(_ review: ShowcasedReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(repeating: "★", count: max(0, min(review.rating, 5))))
                .foregroundStyle(.yellow)
                .accessibilityLabel("\(review.rating) out of 5 stars")
            Text(review.title).font(.headline).lineLimit(2).truncationMode(.tail)
            Text(review.reviewText).lineLimit(5).truncationMode(.tail)
            Text(review.author).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(width: 260, height: 240, alignment: .topLeading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
#endif
