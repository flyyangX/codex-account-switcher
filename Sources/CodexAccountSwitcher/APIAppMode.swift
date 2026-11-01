import Foundation

enum APIAppMode {
    static var isDemo: Bool { ProcessInfo.processInfo.arguments.contains("--api-demo") }
    static var usesIsolatedStartup: Bool {
        isDemo || Bundle.main.object(forInfoDictionaryKey: "APIStandaloneBuild") as? Bool == true
    }
}
