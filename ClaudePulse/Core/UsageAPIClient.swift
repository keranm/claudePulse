import Foundation
import Security
import OSLog

// RateLimitWindow and APIUsageData are defined in UsageCalculator.swift
// (shared with the widget target) — only the network/Keychain client lives here.

private let log = Logger(subsystem: "com.claudepulse.app", category: "UsageAPI")

enum UsageAPIError: Error {
    case keychainError(OSStatus)
    case invalidCredentialFormat
    case httpError(Int)
    case unexpectedResponse
}

final class UsageAPIClient {
    // Ordered Keychain service names to try. Claude Code 2.x stores the OAuth
    // credential under "Claude Code" (or "claude.ai" for the claudeai-proxy
    // transport); older versions used "Claude Code-credentials". The account is
    // the system username, but we match by service only so it isn't hardcoded.
    private static let keychainServices = ["Claude Code", "claude.ai", "Claude Code-credentials"]
    private static let usageEndpoint   = URL(string: "https://claude.ai/api/oauth/usage")!
    private static let minRefreshInterval: TimeInterval = 60

    private var lastFetchDate: Date = .distantPast
    private var cachedResult: APIUsageData?
    private var keychainDeniedUntil: Date = .distantPast

    /// Plan detected from Keychain credentials; nil if unavailable or unrecognised.
    private(set) var detectedPlan: ClaudePlan?

    // Returns cached data if fetched within the last 60s; otherwise hits the API.
    // Returns nil (without throwing) when credentials aren't present.
    func fetchUsage() async throws -> APIUsageData? {
        let now = Date()
        guard now >= keychainDeniedUntil else { return nil }
        if let cached = cachedResult, now.timeIntervalSince(lastFetchDate) < Self.minRefreshInterval {
            return cached
        }

        guard let (token, source) = try readToken() else {
            log.info("No Claude Code credentials in Keychain")
            return nil
        }
        log.debug("Token read (source: \(source)), detectedPlan: \(self.detectedPlan?.rawValue ?? "nil")")

        var request = URLRequest(url: Self.usageEndpoint, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Accept")
        request.setValue("ClaudePulse/1.0",   forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageAPIError.unexpectedResponse }
        guard http.statusCode == 200 else {
            log.warning("Usage API returned HTTP \(http.statusCode)")
            throw UsageAPIError.httpError(http.statusCode)
        }

        let result = parseUsageResponse(data)
        log.info("Usage API: session=\(result?.fiveHour?.usedPercentage ?? -1)% weekly=\(result?.sevenDay?.usedPercentage ?? -1)%")
        lastFetchDate = now
        cachedResult  = result
        return result
    }

    // MARK: - Private

    // Returns (bearerToken, debugSourceLabel) or nil if no credential is found
    // under any known service name.
    private func readToken() throws -> (String, String)? {
        guard let data = try readCredentialData() else { return nil }

        // Credential is stored as JSON: { "claudeAiOauth": { "accessToken": "...", "rateLimitTier": "...", ... } }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Flat token fields at top level
            for key in ["accessToken", "access_token", "token"] {
                if let tok = json[key] as? String, !tok.isEmpty { return (tok, "\(service):\(key)") }
            }
            // Nested object under claudeAiOauth
            if let nested = json["claudeAiOauth"] as? [String: Any] {
                detectedPlan = Self.detectPlan(from: nested)   // detect plan before extracting token
                for key in ["accessToken", "access_token", "token"] {
                    if let tok = nested[key] as? String, !tok.isEmpty {
                        return (tok, "\(service):claudeAiOauth.\(key)")
                    }
                }
            }
            log.error("Keychain JSON has unexpected shape: \(json.keys.sorted())")
            throw UsageAPIError.invalidCredentialFormat
        }

        // Plain-text token fallback
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw UsageAPIError.invalidCredentialFormat }
        return (token, "plaintext")
    }

    // Reads the raw credential blob, or nil if the item doesn't exist.
    //
    // Claude Code recreates the Keychain item on every token refresh, which resets
    // the item's ACL — so a per-app "Always Allow" grant to Claude Pulse never
    // survives, and reading via SecItemCopyMatching prompts for the login password
    // each time. The `security` tool stays on the recreated item's partition list
    // (Claude Code writes through it), so shelling out to it reads without a prompt.
    private func readCredentialData() throws -> Data? {
        if let data = Self.readViaSecurityCLI() {
            return data
        }
        log.debug("security CLI read failed; falling back to SecItemCopyMatching")

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecItemNotFound: return nil
        case errSecSuccess:      break
        case errSecUserCanceled, errSecInteractionNotAllowed:
            keychainDeniedUntil = Date().addingTimeInterval(300)
            log.info("Keychain access denied — backing off 5 minutes")
            return nil
        default:                 throw UsageAPIError.keychainError(status)
        }

        guard let data = result as? Data else { throw UsageAPIError.invalidCredentialFormat }
        return data
    }

    private static func readViaSecurityCLI() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError  = FileHandle.nullDevice

        do { try process.run() } catch {
            log.error("Failed to launch security CLI: \(error.localizedDescription)")
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else { return nil }

        // `-w` appends a trailing newline; strip surrounding whitespace.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Data(trimmed.utf8)
    }

    // MARK: - Response parsing

    // Actual response shape (as of June 2026):
    // { "five_hour": { "utilization": 21.0, "resets_at": "<ISO8601>" },
    //   "seven_day":  { "utilization":  7.0, "resets_at": "<ISO8601>" }, ... }
    private func parseUsageResponse(_ data: Data) -> APIUsageData? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fiveHour = decodeWindow(json["five_hour"])
        let sevenDay = decodeWindow(json["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return APIUsageData(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private func decodeWindow(_ obj: Any?) -> RateLimitWindow? {
        guard let dict    = obj as? [String: Any],
              let pct     = (dict["utilization"] as? Double) ?? (dict["utilization"] as? Int).map(Double.init),
              let resetAt = parseISO(dict["resets_at"])
        else { return nil }
        return RateLimitWindow(usedPercentage: pct, resetsAt: resetAt)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private func parseISO(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        return Self.isoWithFraction.date(from: str) ?? Self.isoPlain.date(from: str)
    }

    // MARK: - Plan detection

    // Maps Keychain fields to a ClaudePlan.
    // Known rateLimitTier values (empirical): "default" → Pro, "max_5x" → Max5, "max_20x" → Max20.
    // subscriptionType provides a coarser signal as fallback.
    private static func detectPlan(from credential: [String: Any]) -> ClaudePlan? {
        let tier = (credential["rateLimitTier"] as? String ?? "").lowercased()
        let sub  = (credential["subscriptionType"] as? String ?? "").lowercased()
        log.info("Keychain rateLimitTier='\(tier)' subscriptionType='\(sub)'")

        // Try rateLimitTier first — it's the most specific signal
        if tier.contains("20") { return .max20 }
        if tier.contains("5")  { return .max5 }
        if tier == "default" || tier == "pro" { return .pro }

        // Fall back to subscriptionType
        if sub.contains("20")  { return .max20 }
        if sub.contains("max") { return .max5 }   // max without a number → assume Max5
        if sub == "pro"        { return .pro }

        return nil  // Unknown — let the user's manual setting stand
    }
}
