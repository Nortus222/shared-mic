import Foundation

/// Version string surfacing for issue 19.
///
/// `CFBundleShortVersionString` / `CFBundleVersion` are stamped at build
/// time from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
/// `macos/project.rb` (source of truth). The menu bar footer reads them
/// back here so the running build always reports what it was stamped with.
public enum AppVersion {
    public static func current(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        case let (nil, build?):
            return build
        case (nil, nil):
            return "?"
        }
    }
}
