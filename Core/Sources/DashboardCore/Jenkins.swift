import Foundation

/// A Jenkins build, as a commit status links to it.
public struct JenkinsBuild: Equatable, Hashable, Sendable {
    /// The job, ending in a slash: `https://ci.example.com/job/app/job/PR-7/`.
    public let job: URL
    public let number: Int

    public init(job: URL, number: Int) {
        self.job = job
        self.number = number
    }

    /// Reads the classic link (`/job/app/job/PR-7/8/display/redirect`) and the Blue Ocean one
    /// (`/blue/organizations/jenkins/app/detail/PR-7/8/pipeline`); nil for anything else.
    public init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }

        var prefix: [String] = []
        var names: [String] = []
        var number: Int?
        if let blue = parts.firstIndex(of: "blue"), parts.count > blue + 6,
           parts[blue + 1] == "organizations", parts[blue + 4] == "detail" {
            // The pipeline's full name arrives as one segment with encoded slashes: app%2Fprs%2Fmain.
            prefix = Array(parts[..<blue])
            names = parts[blue + 3].split(separator: "/").map(String.init) + [parts[blue + 5]]
            number = Int(parts[blue + 6])
        } else if let first = parts.firstIndex(of: "job") {
            prefix = Array(parts[..<first])
            var index = first
            while index + 1 < parts.count, parts[index] == "job" {
                names.append(parts[index + 1])
                index += 2
            }
            number = index < parts.count ? Int(parts[index]) : nil
        }
        guard let number, number > 0, !names.isEmpty, !names.contains(where: { $0.isEmpty || $0 == ".." }) else {
            return nil
        }

        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let path = (prefix + names.flatMap { ["job", $0] })
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
        components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.percentEncodedPath = "/" + path + "/"
        guard let job = components.url else { return nil }
        self.init(job: job, number: number)
    }

    /// True when the build lives on `server`: same scheme, host and port, and under its path.
    public func isOn(_ server: URL) -> Bool {
        guard job.scheme?.lowercased() == server.scheme?.lowercased(),
              job.host?.lowercased() == server.host?.lowercased(),
              job.port == server.port
        else { return false }
        let base = server.path.hasSuffix("/") ? server.path : server.path + "/"
        return job.path.hasPrefix(base) || (job.path + "/").hasPrefix(base)
    }
}

public struct JenkinsCredentials: Sendable, Equatable {
    public let server: URL
    public let user: String
    public let token: String

    public init(server: URL, user: String, token: String) {
        self.server = server
        self.user = user
        self.token = token
    }
}

public enum JenkinsError: LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case notFound
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Jenkins rejected the user name or API token. Check them in Settings."
        case .forbidden: return "Jenkins does not let this account start that job."
        case .notFound: return "Jenkins no longer has that job."
        case .http(let code): return "Jenkins returned HTTP \(code)."
        }
    }
}

public protocol JenkinsRestarting: Sendable {
    /// Starts the build's job again.
    func restart(_ build: JenkinsBuild, credentials: JenkinsCredentials) async throws
}

/// Starts Jenkins jobs through the remote access API, signed in with a user's API token.
public struct JenkinsClient: JenkinsRestarting {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    public func restart(_ build: JenkinsBuild, credentials: JenkinsCredentials) async throws {
        // A job with parameters only starts from buildWithParameters, which takes their defaults;
        // a job without them refuses that address and starts from build.
        var lastStatus = 0
        for endpoint in ["buildWithParameters", "build"] {
            var request = URLRequest(url: build.job.appendingPathComponent(endpoint), timeoutInterval: 30)
            request.httpMethod = "POST"
            let login = Data("\(credentials.user):\(credentials.token)".utf8).base64EncodedString()
            request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await transport.send(request)
            lastStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch lastStatus {
            case 200...299: return
            case 401: throw JenkinsError.unauthorized
            case 403: throw JenkinsError.forbidden
            case 404: throw JenkinsError.notFound
            default: continue
            }
        }
        throw JenkinsError.http(lastStatus)
    }
}
