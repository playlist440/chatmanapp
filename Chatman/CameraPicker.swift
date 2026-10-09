import SwiftUI
import UIKit

/// The camera, for sending a picture or a film of what's in front of you.
///
/// The system's own camera screen rather than one built here. It is the one people already
/// know how to use — the shutter is where they expect it, the flash and the front camera are
/// where they expect them — and every hour spent rebuilding that would be an hour spent
/// making something slightly worse.
struct CameraPicker: UIViewControllerRepresentable {

    /// What came back from the camera.
    enum Capture {
        case photo(UIImage)
        case video(URL)
    }

    /// Called with what was taken, or with nothing when someone backed out.
    let onFinish: (Capture?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // Both, with the switch the camera app itself has. A chat app that can only send
        // stills is missing half of what people point a camera at.
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (Capture?) -> Void

        init(onFinish: @escaping (Capture?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let film = info[.mediaURL] as? URL {
                onFinish(.video(film))
                return
            }

            // The edited one when there is one, so a crop someone made is the picture that
            // gets sent rather than the frame they cropped it out of.
            if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
                onFinish(.photo(image))
                return
            }

            onFinish(nil)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
