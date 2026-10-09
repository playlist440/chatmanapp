import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

/// A film picked from the photo library, kept on disk rather than in memory.
///
/// `loadTransferable(type: Data.self)` would also work and is one line shorter, and it is the
/// reason a long video could never be sent: it reads the whole film into memory, where it is
/// then copied a second time into the request body. Four hundred megabytes twice over is not
/// a slow send, it is the system ending the app mid-upload.
struct LibraryVideo: Transferable {

    /// Where it landed. Ours, and ours to delete once it has gone out.
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { film in
            SentTransferredFile(film.url)
        } importing: { received in
            // Copied before returning: the file the picker offers is taken away again the
            // moment this closure ends, and what is left is a path to nothing.
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)

            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }

    /// How large it is on screen, the right way up.
    ///
    /// A film shot in portrait is stored landscape with an instruction to turn it a quarter
    /// turn. Sending the stored size would tell the other end to make a letterbox of
    /// something that is taller than it is wide.
    var dimensions: CGSize? {
        get async {
            let asset = AVURLAsset(url: url)

            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else { return nil }

            let turned = size.applying(transform)
            return CGSize(width: abs(turned.width), height: abs(turned.height))
        }
    }
}
