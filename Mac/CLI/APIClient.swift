import Foundation
import MacrophoneKit

/// A thin client for the Mac app's local API (docs/API.md). Reads the port and token from
/// ~/Library/Application Support/Macrophone/api.json, which the app writes.
enum ClientError: Error {
    case notRunning
    case unauthorized
    case http(Int, String)

    var exitCode: Int32 {
        switch self {
        case .notRunning: return 3
        case .unauthorized: return 4
        case .http: return 1
        }
    }

    var message: String {
        switch self {
        case .notRunning:
            return "Macrophone isn't running — open it, then try again. (If it's open, turn on Local API in Macrophone › Developer.)"
        case .unauthorized:
            return "Macrophone didn't accept the token. Open Macrophone › Developer and try again."
        case .http(let code, let body):
            return "Macrophone answered \(code)\(body.isEmpty ? "" : ": \(body)")"
        }
    }
}

struct APIClient {
    let config: APIConfig

    static func make() throws -> APIClient {
        guard let c = APIConfig.load() else { throw ClientError.notRunning }
        return APIClient(config: c)
    }

    private static func session(timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }

    func request(_ pathAndQuery: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)\(pathAndQuery)")!)
        r.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        r.setValue("macrophone-cli", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// GET; returns (status, body). Throws notRunning / unauthorized.
    func get(_ pathAndQuery: String, timeout: TimeInterval = 15) async throws -> (Int, Data) {
        do {
            let (data, resp) = try await Self.session(timeout: timeout).data(for: request(pathAndQuery))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { throw ClientError.unauthorized }
            if code >= 400 {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
                throw ClientError.http(code, msg)
            }
            return (code, data)
        } catch let e as ClientError {
            throw e
        } catch {
            throw ClientError.notRunning
        }
    }
}
