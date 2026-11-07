#if canImport(SwiftUI) && canImport(UIKit) && canImport(AuthenticationServices) && canImport(WebKit)
import AuthenticationServices
import SwiftUI
import UIKit
import WebKit

/// A button that presents the FeatureBerry roadmap as a native sheet.
@MainActor
public struct FeatureBerryFeatureBoardButton: View {
    private let appShortName: String
    private let apiKey: String
    private let baseURL: URL
    private let title: String
    @State private var isPresented = false

    public init(
        appShortName: String,
        apiKey: String,
        baseURL: URL = FeatureBerryConfiguration.defaultBaseURL,
        title: String = "Feature Board"
    ) {
        self.appShortName = appShortName
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.title = title
    }

    public var body: some View {
        Button(title) { isPresented = true }
        .sheet(isPresented: $isPresented) {
            FeatureBoardView(appShortName: appShortName, apiKey: apiKey, baseURL: baseURL)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// Presents the Feature Board from a UIKit view controller, such as a list selection handler.
@MainActor
public enum FeatureBerryFeatureBoard {
    public static func present(
        from presenter: UIViewController,
        appShortName: String,
        apiKey: String,
        baseURL: URL = FeatureBerryConfiguration.defaultBaseURL
    ) {
        let controller = UIHostingController(
            rootView: FeatureBoardView(appShortName: appShortName, apiKey: apiKey, baseURL: baseURL))
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: true)
    }
}

@MainActor
private struct FeatureBoardView: View {
    private enum BoardTab: Hashable {
        case open
        case closed
    }

    private enum PendingAction {
        case vote(String)
        case suggest(String, String)
    }

    let appShortName: String
    let apiKey: String
    let baseURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var response: FeatureBerryRoadmapResponse?
    @State private var selectedTab = BoardTab.open
    @State private var navigationPath: [URL] = []
    @State private var isLoading = true
    @State private var isShowingSuggestion = false
    @State private var isShowingSignIn = false
    @State private var suggestionName = ""
    @State private var suggestionDescription = ""
    @AppStorage private var email: String
    @State private var pendingAction: PendingAction?
    @State private var votedCodewords: Set<String> = []
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    init(appShortName: String, apiKey: String, baseURL: URL) {
        self.appShortName = appShortName
        self.apiKey = apiKey
        self.baseURL = baseURL
        _email = AppStorage(wrappedValue: "", "featureberry.email.\(appShortName)")
    }

    private var client: FeatureBoardClient {
        FeatureBoardClient(configuration: FeatureBoardConfiguration(
            appShortName: appShortName, apiKey: apiKey, baseURL: baseURL))
    }

    private var features: [FeatureBerryRoadmapFeature] {
        response?.features.filter { isClosed($0) == (selectedTab == .closed) } ?? []
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")

                Spacer()
                Text("Feature Board")
                    .font(.title2.bold())
                Spacer()

                Button {
                    isShowingSuggestion = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Suggest a feature")
            }
            .padding(.horizontal)

            Picker("Feature status", selection: $selectedTab) {
                Text("Open (\(count(closed: false)))").tag(BoardTab.open)
                Text("Closed (\(count(closed: true)))").tag(BoardTab.closed)
            }
            .pickerStyle(.segmented)
            .padding()

            if isLoading {
                Spacer()
                ProgressView("Loading features")
                Spacer()
            } else if let errorMessage, response == nil {
                ContentUnavailableView(errorMessage, systemImage: "wifi.exclamationmark")
                Spacer()
            } else if features.isEmpty {
                ContentUnavailableView("No features yet", systemImage: "lightbulb")
                Spacer()
            } else {
                List(features) { feature in
                    FeatureBoardRow(
                        feature: feature,
                        detailURL: featureWebURL(feature),
                        hasVoted: feature.hasVoted || votedCodewords.contains(feature.codeword ?? ""),
                        onVote: { vote(feature) },
                        onOpen: { url in navigationPath.append(url) })
                    .listRowSeparator(.visible)
                }
                .listStyle(.plain)
                .refreshable { await loadFeatures() }
            }
            }
            .navigationBarBackButtonHidden()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            signInFooter
        }
        .task { await loadFeatures() }
        .sheet(isPresented: $isShowingSuggestion) {
            suggestionForm
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingSignIn) {
            FeatureBoardSignIn { authorizedEmail in
                email = authorizedEmail
                isShowingSignIn = false
                Task { await performPendingAction() }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(for: URL.self) { url in
            FeatureBoardWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
        }
        .alert("Feature Board", isPresented: Binding(
            get: { errorMessage != nil || statusMessage != nil },
            set: { if !$0 { errorMessage = nil; statusMessage = nil } })) {
                Button("OK") { errorMessage = nil; statusMessage = nil }
            } message: {
                Text(errorMessage ?? statusMessage ?? "")
            }
    }

    private var signInFooter: some View {
        HStack {
            if email.isEmpty {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email]
                } onCompletion: { result in
                    switch result {
                    case let .success(authorization):
                        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                              let authorizedEmail = AppleSignInEmail.resolve(
                                credentialEmail: credential.email,
                                identityToken: credential.identityToken)
                        else {
                            errorMessage = "Apple did not provide an email address. Try signing in again."
                            return
                        }
                        email = authorizedEmail
                        Task {
                            if pendingAction == nil {
                                await loadFeatures()
                            } else {
                                await performPendingAction()
                            }
                        }
                    case let .failure(error):
                        errorMessage = error.localizedDescription
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
            } else {
                Button {
                    guard let loginURL = URL(string: "https://featureberry.com/Login") else { return }
                    navigationPath.append(loginURL)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "apple.logo")
                        Text(email)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Signed in as \(email). Open 🍓FeatureBerry login")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.black.ignoresSafeArea(edges: .bottom))
    }

    private var suggestionForm: some View {
        NavigationStack {
            Form {
                TextField("Feature name", text: $suggestionName)
                    .textInputAutocapitalization(.sentences)
                TextField("Description (optional)", text: $suggestionDescription, axis: .vertical)
                    .lineLimit(3...6)
            }
            .navigationTitle("Suggest a Feature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isShowingSuggestion = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Submit") { submitSuggestion() }
                        .disabled(suggestionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func count(closed: Bool) -> Int {
        response?.features.filter { isClosed($0) == closed }.count ?? 0
    }

    private func isClosed(_ feature: FeatureBerryRoadmapFeature) -> Bool {
        feature.isClosed
    }

    private func webURL(_ rawValue: String?) -> URL? {
        guard let rawValue, let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private func featureWebURL(_ feature: FeatureBerryRoadmapFeature) -> URL? {
        guard let codeword = feature.codeword?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codeword.isEmpty
        else { return webURL(feature.detailURL) }
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.remove(charactersIn: "/?#%")
        guard let pathComponent = codeword.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return nil
        }
        return URL(string: "https://featureberry.com/f/\(pathComponent)")
    }

    private func loadFeatures() async {
        isLoading = true
        defer { isLoading = false }
        do {
            response = try await client.fetchFeatures()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func vote(_ feature: FeatureBerryRoadmapFeature) {
        guard let codeword = feature.codeword?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codeword.isEmpty
        else {
            errorMessage = "Voting is not available for this feature."
            return
        }
        pendingAction = .vote(codeword)
        if email.isEmpty {
            isShowingSignIn = true
        } else {
            Task { await performPendingAction() }
        }
    }

    private func submitSuggestion() {
        let name = suggestionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        pendingAction = .suggest(name, suggestionDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        isShowingSuggestion = false
        if email.isEmpty {
            isShowingSignIn = true
        } else {
            Task { await performPendingAction() }
        }
    }

    private func performPendingAction() async {
        guard !email.isEmpty, let pendingAction else { return }
        self.pendingAction = nil
        do {
            switch pendingAction {
            case let .vote(codeword):
                try await client.vote(email: email, codeword: codeword)
                votedCodewords.insert(codeword)
                await loadFeatures()
                statusMessage = "Your vote has been recorded."
            case let .suggest(name, description):
                try await client.suggest(FeatureBerryFeatureSuggestion(
                    appShortName: appShortName,
                    apiKey: apiKey,
                    email: email,
                    featureName: name,
                    description: description.isEmpty ? nil : description))
                suggestionName = ""
                suggestionDescription = ""
                statusMessage = "Thanks for your suggestion!"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct FeatureBoardRow: View {
    let feature: FeatureBerryRoadmapFeature
    let detailURL: URL?
    let hasVoted: Bool
    let onVote: () -> Void
    let onOpen: (URL) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onVote) {
                VStack(spacing: 8) {
                    Image(systemName: hasVoted ? "checkmark" : "arrow.up")
                        .font(.system(size: 22, weight: .semibold))
                    Text("\(feature.voteCount)")
                        .font(.subheadline.bold())
                        .frame(minWidth: 34, minHeight: 34)
                        .background(.black.opacity(0.18), in: Circle())
                }
                .foregroundStyle(.white)
                .frame(width: 82, height: 82)
                .background(Color(red: 0.94, green: 0.16, blue: 0.35), in: RoundedRectangle(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                hasVoted
                    ? "You voted for \(feature.title), \(feature.voteCount) votes"
                    : "Vote for \(feature.title), \(feature.voteCount) votes")

            Group {
                if let detailURL {
                    Button { onOpen(detailURL) } label: { rowContent }
                        .buttonStyle(.plain)
                } else {
                    rowContent
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(feature.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if detailURL != nil {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            if let description = feature.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let status = feature.horizon ?? feature.status {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(statusBackground(status), in: Capsule())
                    .foregroundStyle(statusForeground(status))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func statusBackground(_ status: String) -> Color {
        let value = status.lowercased()
        if value.contains("progress") { return Color.blue.opacity(0.16) }
        if value.contains("testing") { return Color.yellow.opacity(0.22) }
        if value.contains("shipped") || value.contains("closed") { return Color.green.opacity(0.16) }
        return Color.gray.opacity(0.16)
    }

    private func statusForeground(_ status: String) -> Color {
        let value = status.lowercased()
        if value.contains("progress") { return .blue }
        if value.contains("testing") { return .pink }
        if value.contains("shipped") || value.contains("closed") { return .green }
        return .secondary
    }
}

@MainActor
private struct FeatureBoardSignIn: View {
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Sign in to 🍓FeatureBerry")
                .font(.title2.bold())
            Text("Sign in with Apple to vote or submit a feature suggestion.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                switch result {
                case let .success(authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let email = AppleSignInEmail.resolve(
                            credentialEmail: credential.email,
                            identityToken: credential.identityToken)
                    else {
                        message = "Apple did not provide an email address. Try signing in again."
                        return
                    }
                    onResult(email)
                    dismiss()
                case let .failure(error):
                    message = error.localizedDescription
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            Button("Cancel") { dismiss() }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(24)
    }
}

private struct FeatureBoardWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#endif
