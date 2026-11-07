import Foundation
import Testing
@testable import FeatureBerrySDK
#if canImport(UIKit) && canImport(ReplayKit)
import UIKit
#endif

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite struct FeatureFlagClientTests {
    @Test func horizonRequestUsesExpectedEndpointAndQueryParameters() throws {
        let client = FeatureBerryFeatureClient(
            apiKey: "key & value",
            appShortName: "sample app",
            baseURL: URL(string: "https://portal.featureberry.com")!)

        let request = try client.makeHorizonRequest(codeword: "dark&mode")
        let components = try #require(request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })

        #expect(request.httpMethod == "GET")
        #expect(components.path == "/api/sdk/feature/horizon")
        #expect(components.queryItems?.first(where: { $0.name == "codeword" })?.value == "dark&mode")
        #expect(components.queryItems?.first(where: { $0.name == "apiKey" })?.value == "key & value")
    }

    @Test func featuresRequestUsesExpectedEndpointAndQueryParameters() throws {
        let client = FeatureBerryFeatureClient(
            apiKey: "sdk-key",
            appShortName: "sample app",
            baseURL: URL(string: "https://portal.featureberry.com")!)

        let request = try client.makeFeaturesRequest()
        let components = try #require(request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })

        #expect(request.httpMethod == "GET")
        #expect(components.path == "/api/sdk/app/features")
        #expect(components.queryItems?.first(where: { $0.name == "appShortName" })?.value == "sample app")
        #expect(components.queryItems?.first(where: { $0.name == "apiKey" })?.value == "sdk-key")
    }

    @Test func featureFlagRequestsRequireHttps() {
        let client = FeatureBerryFeatureClient(
            apiKey: "sdk-key",
            appShortName: "sample",
            baseURL: URL(string: "http://portal.featureberry.com")!)

        #expect(throws: FeatureBerryError.invalidURL) {
            try client.makeHorizonRequest(codeword: "dark-mode")
        }
        #expect(throws: FeatureBerryError.invalidURL) {
            try client.makeFeaturesRequest()
        }
    }

    @Test(arguments: [
        (#""Testing""#, FeatureBerryHorizon.testing),
        (#"{"horizon":"Shipped"}"#, FeatureBerryHorizon.shipped),
        (#"{"status":"UpNext"}"#, FeatureBerryHorizon.upNext)
    ])
    func decodesHorizonResponses(json: String, expected: FeatureBerryHorizon) throws {
        let response = try JSONDecoder().decode(FeatureBerryHorizonResponse.self, from: Data(json.utf8))
        #expect(response.horizon == expected)
    }

    @Test func decodesFeatureListsAsArrayOrEnvelope() throws {
        let array = Data(#"[{"id":7,"title":"Dark mode","codeword":"dark-mode"}]"#.utf8)
        let envelope = Data(#"{"features":[{"id":7,"title":"Dark mode","codeword":"dark-mode"}]}"#.utf8)

        for data in [array, envelope] {
            let response = try JSONDecoder().decode(FeatureBerryAppFeaturesResponse.self, from: data)
            #expect(response.features == [FeatureBerryAppFeature(id: 7, title: "Dark mode", codeword: "dark-mode")])
        }
    }
}

@Suite @MainActor struct FeatureFlagEvaluationTests {
    @Test func configuringPreservesTestingMode() {
        let previousClient = FeatureBerry.client
        FeatureBerry.userIsTesting = true
        defer {
            FeatureBerry.client = previousClient
            FeatureBerry.userIsTesting = false
        }
        FeatureBerry.configure(apiKey: "sdk-key", appShortName: "sample")
        #expect(FeatureBerry.userIsTesting)
    }

    #if canImport(UIKit) && canImport(ReplayKit)
    @Test func startingConfiguredSessionEnablesTestingMode() {
        FeatureBerry.onUserIsTestingChanged = nil
        FeatureBerry.userIsTesting = false
        var changes: [Bool] = []
        FeatureBerry.onUserIsTestingChanged = { changes.append($0) }
        defer {
            FeatureBerry.onUserIsTestingChanged = nil
            FeatureBerry.userIsTesting = false
        }

        let manager = FeatureBerrySessionManager()
        manager.startSession(presentingFrom: UIViewController())
        #expect(!FeatureBerry.userIsTesting)

        manager.configure(apiKey: "sdk-key", testType: .feature, codeword: "test", checklistItems: [])
        manager.startSession(presentingFrom: UIViewController())
        #expect(FeatureBerry.userIsTesting)
        #expect(changes == [true])
    }
    #endif

    @Test func liveFlagsPassOnlyForShippedFeatures() {
        FeatureBerry.cacheHorizon(.shipped, for: "live")
        FeatureBerry.cacheHorizon(.testing, for: "testing")
        FeatureBerry.userIsTesting = false

        #expect(FeatureBerry.Feature("live").Live)
        #expect(!FeatureBerry.Feature("testing").Live)
    }

    @Test func testingFlagsReflectHorizonIndependentlyOfUserOptIn() {
        FeatureBerry.cacheHorizon(.testing, for: "testing")
        FeatureBerry.userIsTesting = false
        #expect(FeatureBerry.Feature("testing").Testing)
        #expect(!(FeatureBerry.Feature("testing").Testing && FeatureBerry.userIsTesting))

        FeatureBerry.userIsTesting = true
        #expect(FeatureBerry.Feature("testing").Testing)
        #expect(FeatureBerry.Feature("testing").Testing && FeatureBerry.userIsTesting)

        FeatureBerry.cacheHorizon(.shipped, for: "shipped")
        #expect(!FeatureBerry.Feature("shipped").Testing)
        FeatureBerry.userIsTesting = false
    }

    @Test func liveOrUserIsTestingFlagsPassForLiveOrOptedInTestingFeatures() {
        FeatureBerry.cacheHorizon(.shipped, for: "live")
        FeatureBerry.cacheHorizon(.testing, for: "testing")
        FeatureBerry.cacheHorizon(.upNext, for: "up-next")
        defer { FeatureBerry.userIsTesting = false }

        FeatureBerry.userIsTesting = false
        #expect(FeatureBerry.Feature("live").LiveOrUserIsTesting)
        #expect(!FeatureBerry.Feature("testing").LiveOrUserIsTesting)
        #expect(!FeatureBerry.Feature("up-next").LiveOrUserIsTesting)

        FeatureBerry.userIsTesting = true
        #expect(FeatureBerry.Feature("live").LiveOrUserIsTesting)
        #expect(FeatureBerry.Feature("testing").LiveOrUserIsTesting)
        #expect(!FeatureBerry.Feature("up-next").LiveOrUserIsTesting)
    }

    @Test func testingModeChangesNotifyTheHostOncePerChange() {
        FeatureBerry.onUserIsTestingChanged = nil
        FeatureBerry.userIsTesting = false
        var changes: [Bool] = []
        let notifications = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: FeatureBerry.userIsTestingChangedNotification, object: nil, queue: nil
        ) { _ in
            notifications.increment()
        }
        FeatureBerry.onUserIsTestingChanged = { changes.append($0) }
        defer {
            FeatureBerry.onUserIsTestingChanged = nil
            NotificationCenter.default.removeObserver(observer)
            FeatureBerry.userIsTesting = false
        }

        FeatureBerry.userIsTesting = true
        #expect(FeatureBerry.isTestingSessionEnabled)
        FeatureBerry.userIsTesting = true
        FeatureBerry.userIsTesting = false
        #expect(!FeatureBerry.isTestingSessionEnabled)
        #expect(changes == [true, false])
        #expect(notifications.count == 2)
    }

    @Test func expiredHorizonCacheDoesNotEnableAFlag() {
        FeatureBerry.cacheHorizon(
            .shipped,
            for: "expired",
            fetchedAt: Date().addingTimeInterval(-FeatureBerry.horizonCacheDuration - 1))

        #expect(!FeatureBerry.Feature("expired").Live)
    }

    @Test func refreshRequiresConfiguration() async {
        await #expect(throws: FeatureBerryError.featureFlagsNotConfigured) {
            try await FeatureBerry.refreshFeature(codeword: "unknown")
        }
        await #expect(throws: FeatureBerryError.featureFlagsNotConfigured) {
            try await FeatureBerry.refreshFeatures()
        }
    }
}

@Suite @MainActor struct WhatsNewVersionTests {
    @Test func checksWhenBundleVersionChanges() {
        #expect(FeatureBerry.shouldCheckWhatsNew(currentVersion: "2.0", lastVersion: "1.9"))
        #expect(FeatureBerry.shouldCheckWhatsNew(currentVersion: "2.0", lastVersion: nil))
    }

    @Test func skipsUnchangedOrMissingBundleVersions() {
        #expect(!FeatureBerry.shouldCheckWhatsNew(currentVersion: "2.0", lastVersion: "2.0"))
        #expect(!FeatureBerry.shouldCheckWhatsNew(currentVersion: nil, lastVersion: "2.0"))
        #expect(!FeatureBerry.shouldCheckWhatsNew(currentVersion: "  ", lastVersion: nil))
    }

    @Test func alwaysShowOverridesVersionChecks() {
        #expect(FeatureBerry.shouldCheckWhatsNew(
            currentVersion: "2.0", lastVersion: "2.0", alwaysShow: true))
        #expect(FeatureBerry.shouldCheckWhatsNew(
            currentVersion: nil, lastVersion: nil, alwaysShow: true))
    }

    @Test func readsAlwaysShowFromInfoDictionary() {
        #expect(FeatureBerry.shouldAlwaysShowWhatsNew(from: ["ShowWhatsNewAlways": 1]))
        #expect(!FeatureBerry.shouldAlwaysShowWhatsNew(from: ["ShowWhatsNewAlways": 0]))
        #expect(!FeatureBerry.shouldAlwaysShowWhatsNew(from: [:]))
        #expect(!FeatureBerry.shouldAlwaysShowWhatsNew(from: nil))
    }

    @Test func bundleVersionIncludesMarketingAndBuildVersions() {
        #expect(FeatureBerry.whatsNewVersion(from: [
            "CFBundleShortVersionString": "2.0",
            "CFBundleVersion": "42"
        ]) == "2.0+42")
        #expect(FeatureBerry.whatsNewVersion(from: ["CFBundleVersion": "42"]) == "42")
        #expect(FeatureBerry.whatsNewVersion(from: [:]) == nil)
    }
}
