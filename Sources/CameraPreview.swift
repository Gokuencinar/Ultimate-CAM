import AVFoundation
import SwiftUI
import UIKit

final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let ring = UIView()
    private let caption = UILabel()
    private var dismissFocus: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "camera.viewfinder"
        accessibilityLabel = "Visor. Toca para enfocar o mantén pulsado para bloquear enfoque y exposición."
        isAccessibilityElement = true
        ring.isUserInteractionEnabled = false
        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.borderWidth = 1.5
        ring.layer.cornerRadius = 10
        ring.isHidden = true
        addSubview(ring)
        caption.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .black
        caption.backgroundColor = UIColor(red:0.77,green:0.84,blue:0.99,alpha:1)
        caption.textAlignment = .center
        caption.layer.cornerRadius = 5
        caption.clipsToBounds = true
        caption.isUserInteractionEnabled = false
        caption.accessibilityIdentifier = "focus.reticle"
        caption.isHidden = true
        addSubview(caption)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
    func showFocus(at point: CGPoint, locked: Bool) {
        dismissFocus?.cancel()
        let center = CGPoint(x: min(max(36, point.x), max(36, bounds.width - 36)),
                             y: min(max(48, point.y), max(48, bounds.height - 48)))
        ring.frame = CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60)
        caption.frame = CGRect(x: center.x - 44, y: center.y + 33, width: 88, height: 22)
        caption.text = locked ? "AF / AE LOCK" : "AF / AE"
        ring.isHidden = false
        caption.isHidden = false
        ring.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        UIView.animate(withDuration: 0.18) { self.ring.transform = .identity }
        let task = DispatchWorkItem { [weak self] in
            self?.ring.isHidden = true
            self?.caption.isHidden = true
        }
        dismissFocus = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let zoom: Double
    let focus: (CGPoint, Bool) -> Void
    let changeZoom: (Double) -> Void

    final class Coordinator: NSObject {
        var parent: CameraPreview
        var startingZoom = 1.0
        init(_ parent: CameraPreview) { self.parent = parent }
        func focus(_ gesture: UIGestureRecognizer, locked: Bool) {
            guard let view = gesture.view as? PreviewSurface else { return }
            let location = gesture.location(in: view)
            let point = view.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
            view.showFocus(at: location, locked: locked)
            CaptureTrace.record(locked ? "ui.focus.longPress" : "ui.focus.tap", ["x": point.x, "y": point.y])
            parent.focus(point, locked)
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) { focus(gesture, locked: false) }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { focus(gesture, locked: true) }
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { startingZoom = parent.zoom }
            if gesture.state == .began || gesture.state == .changed {
                parent.changeZoom(startingZoom * Double(gesture.scale))
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.55
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) { context.coordinator.parent = self }
}
