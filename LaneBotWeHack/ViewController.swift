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
            print("📤 Sending frame to Python")
            sendFrameToPython(resizedImage) { processedImage in
                if let finalImage = processedImage {
                    print("✅ Got processed image from Python")
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

// MARK: - UIImage Extension
/*extension UIImage {
    func rotated(by degrees: CGFloat) -> UIImage {
        let radians = degrees * (.pi / 180)
        var newSize = CGRect(origin: .zero, size: self.size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size

        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        let context = UIGraphicsGetCurrentContext()!

        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        context.rotate(by: radians)
        draw(in: CGRect(x: -size.width / 2, y: -size.height / 2,
                        width: size.width, height: size.height))

        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return rotatedImage ?? self
    }
}*/

/*import AVFoundation
import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVAudioPlayerDelegate {
    
    // Capture
    var bufferSize: CGSize = .zero
    var inferenceTime: CFTimeInterval  = 0;
    private let session = AVCaptureSession()
    var audioPlayer: AVAudioPlayer?
    var isAlertSoundPlaying = false
    var redTintView: UIView?
    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var alertLabel: UILabel!
    
    
    
    // UI/Layers
    @IBOutlet weak var previewView: UIView!
    var rootLayer: CALayer! = nil
    private var previewLayer: AVCaptureVideoPreviewLayer! = nil
    private var detectionLayer: CALayer! = nil
    private var inferenceTimeLayer: CALayer! = nil
    private var inferenceTimeBounds: CGRect! = nil
    
    // Vision
    private var requests = [VNRequest]()
    
    // Setup
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCapture()
        setupOutput()
        setupLayers()
        imageView.frame = previewView.bounds
        imageView.contentMode = .scaleAspectFill
        previewView.addSubview(imageView)
        previewView.bringSubviewToFront(imageView)
        //try? setupVision()
        //session.startRunning()
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }
    func updateAlertBubble(with alerts: [String]) {
        if alerts.isEmpty {
            alertLabel.text = ""
            alertLabel.isHidden = true
            return
        }
        
        alertLabel.isHidden = false
        alertLabel.text = alerts.joined(separator: "\n")
        
        // Optional: red background if alert is serious
        alertLabel.backgroundColor = .red.withAlphaComponent(0.7)
        
        // Play sounds
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
    func sendFrameToPython(_ image: UIImage, completion: @escaping (UIImage?) -> Void) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else { return }
        let base64String = imageData.base64EncodedString()
        
        let json: [String: Any] = ["image": base64String]
        let jsonData = try! JSONSerialization.data(withJSONObject: json)
        
        let url = URL(string: "https://6c73-35-197-19-71.ngrok-free.app/detect")! // 🔁 Replace with your Colab ngrok link
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
            }
            else {
                print("Error or bad response: \(error?.localizedDescription ?? "unknown error")")
                completion(nil)
            }
        }.resume()
    }
    
    func playSound(named soundFileName: String) {
        // If the sound is already playing, don't try to play it again
        guard !isAlertSoundPlaying else { return }
        
        guard let url = Bundle.main.url(forResource: soundFileName, withExtension: "wav") else {
            print("Sound file named \(soundFileName) not found.")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self // Set the delegate to self
            isAlertSoundPlaying = true // Set the flag to true
            audioPlayer?.play()
        } catch {
            print("Couldn’t load the sound file named \(soundFileName): \(error)")
            isAlertSoundPlaying = false // Reset the flag if the sound couldn't be played
        }
    }
    
    
    /*func setupCapture() {
     var deviceInput: AVCaptureDeviceInput!
     let videoDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back).devices.first
     do {
     deviceInput = try AVCaptureDeviceInput(device: videoDevice!)
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
     try  videoDevice!.lockForConfiguration()
     let dimensions = CMVideoFormatDescriptionGetDimensions((videoDevice?.activeFormat.formatDescription)!)
     bufferSize.width = CGFloat(dimensions.width)
     bufferSize.height = CGFloat(dimensions.height)
     videoDevice!.unlockForConfiguration()
     } catch {
     print(error)
     }
     session.commitConfiguration()
     }*/
    func setupCapture() {
        var deviceInput: AVCaptureDeviceInput!
        
        // Safely unwrap the video device
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
        let videoDataOutputQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
        
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
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        rootLayer = previewView.layer
        previewLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(previewLayer)
        
        inferenceTimeBounds = CGRect(x: rootLayer.frame.midX-75, y: rootLayer.frame.maxY-70, width: 150, height: 17)
        
        inferenceTimeLayer = createRectLayer(inferenceTimeBounds, [1,1,1,1])
        inferenceTimeLayer.cornerRadius = 7
        rootLayer.addSublayer(inferenceTimeLayer)
        
        redTintView = UIView(frame: rootLayer.bounds)
        redTintView?.backgroundColor = UIColor.red.withAlphaComponent(0.5) // Semi-transparent
        redTintView?.isHidden = true // Hidden by default
        redTintView?.isUserInteractionEnabled = false // Disable user interaction
        rootLayer.addSublayer(redTintView!.layer)
        
        detectionLayer = CALayer()
        detectionLayer.bounds = CGRect(x: 0.0,
                                       y: 0.0,
                                       width: bufferSize.width,
                                       height: bufferSize.height)
        detectionLayer.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)
        rootLayer.addSublayer(detectionLayer)
        
        let xScale: CGFloat = rootLayer.bounds.size.width / bufferSize.height
        let yScale: CGFloat = rootLayer.bounds.size.height / bufferSize.width
        
        let scale = fmax(xScale, yScale)
        
        // rotate the layer into screen orientation and scale and mirror
        detectionLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(.pi / 2.0)).scaledBy(x: scale, y: -scale))
        // center the layer
        detectionLayer.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)
    }
    
    /*func setupVision() throws {
     //guard let modelURL = Bundle.main.url(forResource: "yolov5n", withExtension: "mlmodelc") else {
     throw NSError(domain: "ViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model file is missing"])
     }
     
     do {
     let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
     let objectRecognition = VNCoreMLRequest(model: visionModel, completionHandler: { (request, error) in
     DispatchQueue.main.async(execute: {
     if let results = request.results {
     self.drawResults(results)
     }
     })
     })
     self.requests = [objectRecognition]
     } catch let error as NSError {
     print("Model loading went wrong: \(error)")
     }
     }*/
    
    /*func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
     guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
     return
     }
     
     let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
     do {
     // returns true when complete https://developer.apple.com/documentation/vision/vnimagerequesthandler/2880297-perform
     let start = CACurrentMediaTime()
     try imageRequestHandler.perform(self.requests)
     inferenceTime = (CACurrentMediaTime() - start)
     
     } catch {
     print(error)
     }
     }*/
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        
        //let uiImage = UIImage(cgImage: cgImage)
        let uiImage = UIImage(cgImage: cgImage).rotated(by: 90) // Try 90 or -90
        
        
        // Optional: Resize image to reduce payload
        let resizedImage = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: CGSize(width: 320, height: 240)))
        }
        
        // ⚠️ Only send one frame every 1-2 seconds (avoid overload)
        
        if shouldSendFrame() {
            print("Sending frame to Python")
            sendFrameToPython(resizedImage) { processedImage in
                if let finalImage = processedImage {
                    print("Got processed image from Python")
                    DispatchQueue.main.async {
                        self.imageView.image = finalImage // Replace with your UIImageView or rendering logic
                    }
                }
            }
        }
        
        /*if shouldSendFrame() {
         isSending = true
         sendFrameToPython(resizedImage) { processedImage in
         DispatchQueue.main.async {
         if let finalImage = processedImage {
         self.imageView.image = finalImage
         }
         self.isSending = false // reset only after done
         }
         }
         }
         }*/
        var lastFrameSent: Date = .distantPast
        //var isSending = false
        func shouldSendFrame() -> Bool {
            //return !isSending
            let now = Date()
            if now.timeIntervalSince(lastFrameSent) > 0.2 { // every 1.5 sec
                lastFrameSent = now
                return true
            }
            return false
        }
        
        func drawResults(_ results: [Any]) {
            CATransaction.begin()
            CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
            detectionLayer.sublayers = nil // Clear previous detections from detectionLayer
            inferenceTimeLayer.sublayers = nil
            for observation in results where observation is VNRecognizedObjectObservation {
                guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                    continue
                }
                
                // Detection with highest confidence
                guard let topLabelObservation = objectObservation.labels.first else { continue }
                
                // Rotate the bounding box into screen orientation
                let boundingBox = CGRect(origin: CGPoint(x: 1.0 - objectObservation.boundingBox.origin.y - objectObservation.boundingBox.size.height,
                                                         y: objectObservation.boundingBox.origin.x),
                                         size: CGSize(width: objectObservation.boundingBox.size.height,
                                                      height: objectObservation.boundingBox.size.width))
                
                let objectBounds = VNImageRectForNormalizedRect(boundingBox, Int(bufferSize.width), Int(bufferSize.height))
                
                // Get color for the identifier, or use a default color if not found
                let color = colors[topLabelObservation.identifier] ?? UIColor.red.cgColor as! [CGFloat] // Default to red if color not found
                
                let shapeLayer = createRectLayer(objectBounds, color)
                
                // Calculate the size of the bounding box in the appropriate scale
                let width = objectBounds.size.width
                let height = objectBounds.size.height
                let sizeString = String(format: "%.2f x %.2f", width, height)
                
                // Combine label, confidence, and size information
                let labelString = String(format: "%@\n%.1f%%\nSize: %@", topLabelObservation.identifier.capitalized, topLabelObservation.confidence * 100, sizeString)
                let formattedString = NSMutableAttributedString(string: labelString)
                //if(formattedString.string.contains("Traffic")) {
                let textLayer = createDetectionTextLayer(objectBounds, formattedString)
                shapeLayer.addSublayer(textLayer)
                detectionLayer.addSublayer(shapeLayer)
                //}
                
                let objectArea = objectBounds.width * objectBounds.height
                let screenArea = bufferSize.width * bufferSize.height
                if objectArea / screenArea > 0.15 {
                    DispatchQueue.main.async {
                        self.redTintView?.isHidden = false
                        self.playSound(named: "alert")
                        // Hide the red tint view after a second
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.redTintView?.isHidden = true
                        }
                    }
                }
                
                let label = topLabelObservation.identifier.lowercased()
                if label.contains("traffic light") { // Assuming "traffic light" is the identifier used in the model
                    playSound(named: "red")
                }
                
                let formattedInferenceTimeString = NSMutableAttributedString(string: String(format: "Inference time: %.1f ms", inferenceTime * 1000))
                
                let inferenceTimeTextLayer = createInferenceTimeTextLayer(inferenceTimeBounds, formattedInferenceTimeString)
                inferenceTimeLayer.addSublayer(inferenceTimeTextLayer)
                
                CATransaction.commit()
            }
            
            // Clean up capture setup
            func teardownAVCapture() {
                previewLayer.removeFromSuperlayer()
                previewLayer = nil
            }
            
        }
    }
    
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            // When the audio player finishes playing, reset the flag
            isAlertSoundPlaying = false
        }
        
        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            // If there is a decode error, also reset the flag
            print("Audio player decode error: \(String(describing: error))")
            isAlertSoundPlaying = false
        }
}*/
