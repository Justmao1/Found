import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum ReportPhotoSource: Equatable { case camera, library }

/// Delivers a prepared photo only after the system picker has finished dismissing.
struct ReportPhotoAcquisition: ViewModifier {
    @Binding var source: ReportPhotoSource?
    @Binding var importing: Bool
    let onPhoto: (Data) -> Void
    @Environment(\.staffToolsEnabled) private var staffToolsEnabled
    @Environment(\.openURL) private var openURL
    @State private var cameraPresented = false
    @State private var libraryPresented = false
    @State private var pickerTransitioning = false
    @State private var preparedPhoto: Data?
    @State private var pendingError: String?
    @State private var displayedError: String?
    @State private var permissionDenied = false

    func body(content: Content) -> some View {
        content
            .task(id: source) {
                guard let source else { return }
                if source == .library {
                    guard staffToolsEnabled else { self.source = nil; return }
                    pickerTransitioning = true
                    libraryPresented = true
                } else {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        self.source = nil
                        displayedError = "The station camera is unavailable. Please ask staff for help."
                        return
                    }
                    let status = AVCaptureDevice.authorizationStatus(for: .video)
                    let granted = status == .notDetermined
                        ? await AVCaptureDevice.requestAccess(for: .video) : status == .authorized
                    guard !Task.isCancelled else { return }
                    if granted {
                        pickerTransitioning = true
                        cameraPresented = true
                    } else {
                        self.source = nil
                        permissionDenied = true
                    }
                }
            }
            .fullScreenCover(isPresented: $cameraPresented, onDismiss: pickerDidDismiss) {
                CameraPicker(onCapture: { image in
                    importing = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Result { try PhotoProcessor.jpeg(from: image) }
                        DispatchQueue.main.async {
                            switch result {
                            case .success(let photo): preparedPhoto = photo
                            case .failure(let error): pendingError = error.localizedDescription
                            }
                            importing = false
                            finishIfReady()
                        }
                    }
                }, onFailure: { pendingError = $0.localizedDescription })
                .ignoresSafeArea()
                .modifier(VisitorSessionOverlay())
            }
            .sheet(isPresented: $libraryPresented, onDismiss: pickerDidDismiss) {
                ReportLibraryPicker(onStart: { importing = true }, onResult: { result in
                    switch result {
                    case .success(let photo): preparedPhoto = photo
                    case .failure(let error): pendingError = error.localizedDescription
                    }
                    importing = false
                    finishIfReady()
                })
                .ignoresSafeArea()
                .modifier(VisitorSessionOverlay())
            }
            .alert("Camera access is off", isPresented: $permissionDenied) {
                if staffToolsEnabled {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Please ask staff to enable the camera on this station.")
            }
            .alert("Couldn’t use this photo", isPresented: Binding(
                get: { displayedError != nil }, set: { if !$0 { displayedError = nil } }
            )) {
                Button("OK", role: .cancel) { displayedError = nil }
            } message: { Text(displayedError ?? "Please choose another photo.") }
    }

    private func pickerDidDismiss() {
        pickerTransitioning = false
        source = nil
        finishIfReady()
    }

    private func finishIfReady() {
        guard !pickerTransitioning else { return }
        if let preparedPhoto {
            self.preparedPhoto = nil
            onPhoto(preparedPhoto)
        }
        if let pendingError {
            self.pendingError = nil
            displayedError = pendingError
        }
    }
}

/// The system photo picker, with an explicit dismissal boundary for the review sheet.
private struct ReportLibraryPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onStart: () -> Void
    let onResult: (Result<Data, Error>) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: ReportLibraryPicker
        init(parent: ReportLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { parent.dismiss(); return }
            let deliver = parent.onResult
            parent.onStart()
            parent.dismiss()
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                // Image decoding/downsampling runs away from the main thread.
                let result = Result<Data, Error> {
                    if let error { throw error }
                    guard let data else { throw PhotoProcessor.ProcessingError.invalidImage }
                    return try PhotoProcessor.jpeg(from: data)
                }
                DispatchQueue.main.async { deliver(result) }
            }
        }
    }
}
