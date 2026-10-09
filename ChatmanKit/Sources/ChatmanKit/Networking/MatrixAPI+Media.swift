import Foundation

extension MatrixAPI {

    /// An `mxc://` URI split into the parts the media endpoints need.
    struct MediaID {
        let serverName: String
        let mediaID: String

        /// Parses `mxc://server.example/AbCdEf`.
        init?(mxc: String) {
            guard mxc.hasPrefix("mxc://") else { return nil }

            let rest = mxc.dropFirst("mxc://".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }

            serverName = String(rest[..<slash])
            mediaID = String(rest[rest.index(after: slash)...])

            guard !serverName.isEmpty, !mediaID.isEmpty else { return nil }
        }
    }

    /// A request that downloads an attachment at full size.
    ///
    /// Media has required authentication since Matrix 1.11, which is why this returns a
    /// prepared `URLRequest` rather than a plain URL: a bare URL in `AsyncImage` would come
    /// back as a 401. Anything displaying media has to go through here.
    public func mediaRequest(for mxcURL: String) -> URLRequest? {
        guard let media = MediaID(mxc: mxcURL),
              let accessToken,
              let url = homeserver.endpoint(
                "/_matrix/client/v1/media/download/\(media.serverName.pathEscaped)/\(media.mediaID.pathEscaped)"
              )
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// A request for a scaled-down version of an image.
    ///
    /// Always prefer this over the full download when showing a list or a small bubble. On a
    /// watch the difference is the whole ballgame: a full-size photo is megabytes over
    /// cellular to fill a screen 410 points wide.
    public func thumbnailRequest(
        for mxcURL: String,
        width: Int,
        height: Int,
        crop: Bool = true
    ) -> URLRequest? {
        guard let media = MediaID(mxc: mxcURL),
              let accessToken
        else { return nil }

        let query = [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "method", value: crop ? "crop" : "scale")
        ]

        guard let url = homeserver.endpoint(
            "/_matrix/client/v1/media/thumbnail/\(media.serverName.pathEscaped)/\(media.mediaID.pathEscaped)",
            query: query
        ) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Downloads media into memory.
    private struct UploadResponse: Decodable {
        let contentURI: String
        enum CodingKeys: String, CodingKey { case contentURI = "content_uri" }
    }

    /// Uploads a file and returns the `mxc://` address the server stored it under.
    ///
    /// Built by hand rather than through the usual JSON path: this sends raw bytes with the
    /// file's own content type, which is the one request in the whole API that isn't JSON.
    public func uploadMedia(
        _ data: Data, filename: String, mimeType: String
    ) async throws -> String {
        let request = try uploadRequest(filename: filename, mimeType: mimeType)
        return try await upload { urlSession in
            var request = request
            request.httpBody = data
            return try await urlSession.data(for: request)
        }
    }

    /// The same, for something already on disk.
    ///
    /// Streamed from the file rather than read into memory first. A photo is a couple of
    /// megabytes and nobody notices; a film from the library is a couple of hundred, and
    /// holding one of those twice over — once as `Data`, once as the request body — is how an
    /// app gets killed halfway through sending a birthday.
    public func uploadMedia(
        fileAt url: URL, filename: String, mimeType: String
    ) async throws -> String {
        let request = try uploadRequest(filename: filename, mimeType: mimeType)
        return try await upload { urlSession in
            try await urlSession.upload(for: request, fromFile: url)
        }
    }

    private func uploadRequest(filename: String, mimeType: String) throws -> URLRequest {
        guard let accessToken else { throw MatrixError.notSignedIn }
        guard let url = homeserver.endpoint(
            "/_matrix/media/v3/upload",
            query: [URLQueryItem(name: "filename", value: filename)]
        ) else { throw MatrixError.invalidHomeserver }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        // An upload over a slow connection can take a while, and a picture that fails halfway
        // is worse than one that takes a moment. A film takes longer still.
        request.timeoutInterval = Self.uploadTimeout
        return request
    }

    private static let uploadTimeout: TimeInterval = 600

    private func upload(
        _ send: (URLSession) async throws -> (Data, URLResponse)
    ) async throws -> String {
        // Through the session that honours the request's ten minutes, not the one that would
        // cut it off after one. See ``MatrixAPI/longRunning``.
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await send(session(allowing: Self.uploadTimeout))
        } catch let error as URLError {
            throw MatrixError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MatrixError.decoding("The server's answer wasn't understood.")
        }

        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(MatrixErrorResponse.self, from: body) {
                throw MatrixError.api(apiError)
            }
            throw MatrixError.unexpectedStatus(http.statusCode)
        }

        guard let decoded = try? JSONDecoder().decode(UploadResponse.self, from: body) else {
            throw MatrixError.decoding("The server didn't say where it put the file.")
        }

        return decoded.contentURI
    }

    public func downloadMedia(_ mxcURL: String) async throws -> Data {
        guard let request = mediaRequest(for: mxcURL) else { throw MatrixError.notSignedIn }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                throw MatrixError.unexpectedStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            return data
        } catch let error as URLError {
            throw MatrixError.network(error)
        }
    }
}
