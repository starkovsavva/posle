import Foundation

package enum ProcessEnvironment {
    package static func withoutSecrets(_ values: [String: String]) -> [String: String] {
        values.filter { key, _ in
            let name = key.uppercased()
            // These can execute code before the child reaches its own checks.
            if name.hasPrefix("DYLD_") || name.hasPrefix("LD_") || name.hasPrefix("BASH_FUNC_")
                || ["BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH", "GLOBIGNORE"].contains(name) { return false }
            return !["API_KEY", "ACCESS_KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "COOKIE"].contains { name.contains($0) }
        }
    }
}
