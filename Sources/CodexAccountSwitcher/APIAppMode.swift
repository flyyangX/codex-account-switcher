import Foundation

enum APIAppMode {
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("--api-demo") }
    static var isLocalIntegratedBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "APIIntegratedBuild") as? Bool == true
    }
    static var usesIsolatedStartup: Bool {
        isDemo || Bundle.main.object(forInfoDictionaryKey: "APIStandaloneBuild") as? Bool == true
    }
}
