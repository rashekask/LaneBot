//
//  ViewController.swift
//  ObjectDetection-CoreML
//
//  Created by Julius Hietala on 16.8.2022.
//
//  ViewController.swift
//  ObjectDetection-CoreML

import AVFoundation
import UIKit
import Vision

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVAudioPlayerDelegate {

    // MARK: - Properties
    var bufferSize: CGSize = .zero
    var inferenceTime: CFTimeInterval = 0
    private let session = AVCaptureSession()
    var audioPlayer: AVAudioPlayer?
    var isAlertSoundPlaying = false
    var redTintView: UIView?
    var lastFrameSent: Date = .distantPast

    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var alertLabel: UILabel!
    @IBOutlet weak var previewView: UIView!

    var rootLayer: CALayer! = nil
    private var previewLayer: AVCaptureVideoPreviewLayer! = nil
    private var detectionLayer: CALayer! = nil
    private var inferenceTimeLayer: CALayer! = nil
    private var inferenceTimeBounds: CGRect! = nil
    private var requests = [VNRequest]()

    // MARK: - View Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCapture()
        setupOutput()
        setupLayers()
        imageView.frame = previewView.bounds
        imageView.contentMode = .scaleAspectFill
        previewView.addSubview(imageView)
        previewView.bringSubviewToFront(imageView)

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    // MARK: - Frame Processing
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let uiImage = UIImage(cgImage: cgImage).rotated(by: 90)
        let resizedImage = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: CGSize(width: 320, height: 240)))
        }

        if shouldSendFrame() {
            print("Sending frame to Python")
            sendFrameToPython(resizedImage) { processedImage in
                if let finalImage = processedImage {
                    print("Got processed image from Python")
                    DispatchQueue.main.async {
                        self.imageView.image = finalImage
                    }
                }
            }
        }
    }

    func shouldSendFrame() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastFrameSent) > 0.5 {
            lastFrameSent = now
            return true
        }
        return false
    }

    // MARK: - Alerts & Sounds
    func updateAlertBubble(with alerts: [String]) {
        if alerts.isEmpty {
            alertLabel.text = ""
            alertLabel.isHidden = true
            return
        }

        alertLabel.isHidden = false
        alertLabel.text = alerts.joined(separator: "\n")
        alertLabel.backgroundColor = .red.withAlphaComponent(0.7)

        for alert in alerts {
            if alert.contains("front") || alert.contains("left") || alert.contains("right") {
                playSound(named: "alert")
                break
            } else if alert.contains("Red traffic light") || alert.contains("🚦") {
                playSound(named: "red")
                break
            }
        }
    }

    func playSound(named soundFileName: String) {
        guard !isAlertSoundPlaying else { return }

        guard let url = Bundle.main.url(forResource: soundFileName, withExtension: "wav") else {
            print("Sound file named \(soundFileName) not found.")
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            isAlertSoundPlaying = true
            audioPlayer?.play()
        } catch {
            print("Couldn't load sound: \(error)")
            isAlertSoundPlaying = false
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isAlertSoundPlaying = false
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("Audio player decode error: \(String(describing: error))")
        isAlertSoundPlaying = false
    }

    // MARK: - Frame Upload
    func sendFrameToPython(_ image: UIImage, completion: @escaping (UIImage?) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else { return }
        let base64String = imageData.base64EncodedString()

        let json: [String: Any] = ["image": base64String]
        let jsonData = try! JSONSerialization.data(withJSONObject: json)

        let url = URL(string: "https://6c73-35-197-19-71.ngrok-free.app/detect")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data,
               let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let base64String = jsonResponse["processed_image"] as? String,
               let processedData = Data(base64Encoded: base64String),
               let processedImage = UIImage(data: processedData) {

                let alerts = jsonResponse["alerts"] as? [String] ?? []

                DispatchQueue.main.async {
                    self.imageView.image = processedImage
                    self.updateAlertBubble(with: alerts)
                }
            } else {
                print("❌ Error or bad response: \(error?.localizedDescription ?? "unknown error")")
                completion(nil)
            }
        }.resume()
    }

    // MARK: - Setup Methods
    func setupCapture() {
        var deviceInput: AVCaptureDeviceInput!

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )

        guard let videoDevice = discoverySession.devices.first else {
            print("No back camera found")
            return
        }

        do {
            deviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            print("Could not create video device input: \(error)")
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard session.canAddInput(deviceInput) else {
            print("Could not add video device input to the session")
            session.commitConfiguration()
            return
        }
        session.addInput(deviceInput)

        do {
            try videoDevice.lockForConfiguration()
            let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            bufferSize.width = CGFloat(dimensions.width)
            bufferSize.height = CGFloat(dimensions.height)
            videoDevice.unlockForConfiguration()
        } catch {
            print("Could not lock device for configuration: \(error)")
        }

        session.commitConfiguration()
    }

    func setupOutput() {
        let videoDataOutput = AVCaptureVideoDataOutput()
        let videoDataOutputQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated)

        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        } else {
            print("Could not add video data output to the session")
            session.commitConfiguration()
            return
        }
    }

    func setupLayers() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        rootLayer = previewView.layer
        previewLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(previewLayer)

        redTintView = UIView(frame: rootLayer.bounds)
        redTintView?.backgroundColor = UIColor.red.withAlphaComponent(0.5)
        redTintView?.isHidden = true
        redTintView?.isUserInteractionEnabled = false
        rootLayer.addSublayer(redTintView!.layer)
    }
}
