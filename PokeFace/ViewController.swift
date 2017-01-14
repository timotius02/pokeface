//
//  ViewController.swift
//  FaceDetection
//

import UIKit
import CoreImage
import AVFoundation


protocol VideoFeedDelegate {
    func videoFeed(_ videoFeed: VideoFeed, didUpdateWithSampleBuffer sampleBuffer: CMSampleBuffer!)
}


var title:String = "PokéFace"
var buffer = 0
var video_state = 0
var camera_position = "front"

class VideoFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // create a serial dispatch queue used for the sample buffer delegate as well as when a still image is captured
    // a serial dispatch queue must be used to guarantee that video frames will be delivered in order
    // see the header doc for setSampleBufferDelegate:queue: for more information
    let outputQueue = DispatchQueue(label: "VideoDataOutputQueue", attributes: [])
    
    var device: AVCaptureDevice?
    
        
    func getDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo) as! [AVCaptureDevice]
        var camera: AVCaptureDevice? = nil
        for device in devices {
            if camera_position == "front" && device.position == .front {
                camera = device
            }
            else if device.position == .back {
                camera = device
            }
        }
        return camera
    }
    
    var input: AVCaptureDeviceInput? = nil
    var delegate: VideoFeedDelegate? = nil
    
    let session: AVCaptureSession = {
        let session = AVCaptureSession()
        session.sessionPreset = AVCaptureSessionPresetHigh
        return session
    }()
    
    let videoDataOutput: AVCaptureVideoDataOutput = {
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [ kCVPixelBufferPixelFormatTypeKey as AnyHashable: NSNumber(value: kCMPixelFormat_32BGRA as UInt32) ]
        output.alwaysDiscardsLateVideoFrames = true
        return output
    }()
    
    func start() throws {
        device = getDevice()
        var error: NSError! = NSError(domain: "Migrator", code: 0, userInfo: nil)
        do {
            try configure()
            session.startRunning()
            return
        } catch let error1 as NSError {
            error = error1
        }
        throw error
    }
    
    func stop() {
        session.stopRunning()
    }
    
    fileprivate func configure() throws {
        var error: NSError! = NSError(domain: "Migrator", code: 0, userInfo: nil)
        do {
            let maybeInput: AnyObject = try AVCaptureDeviceInput(device: device!)
            input = maybeInput as? AVCaptureDeviceInput
            if session.canAddInput(input) {
                session.addInput(input)
                videoDataOutput.setSampleBufferDelegate(self, queue: outputQueue);
                if session.canAddOutput(videoDataOutput) {
                    session.addOutput(videoDataOutput)
                    let connection = videoDataOutput.connection(withMediaType: AVMediaTypeVideo)
                    connection?.videoOrientation = AVCaptureVideoOrientation.portrait
                    return
                } else {
                    print("Video output error.");
                }
            } else {
                print("Video input error. Maybe unauthorised or no camera.")
            }
        } catch let error1 as NSError {
            error = error1
            print("Failed to start capturing video with error: \(error)")
        }
        throw error
    }
    
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        // Update the delegate
        if delegate != nil {
            delegate!.videoFeed(self, didUpdateWithSampleBuffer: sampleBuffer)
        }
    }
}

class FaceObscurationFilter {
    let inputImage: CIImage
    var outputImage: CIImage? = nil
    var originX: CGFloat? = nil
    var originY: CGFloat? = nil
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var radius: CGFloat? = nil
    
    var bounder: UIView!
    var emotion: String
    
    fileprivate lazy var client : ClarifaiClient = ClarifaiClient(appID: clarifaiClientID, appSecret: clarifaiClientSecret)
    
    var delegate: ViewControllerDelegate?
    
    init(inputImage: CIImage) {
        self.inputImage = inputImage
        self.emotion = "None"
        recognizeImage(UIImage(ciImage: inputImage))
    }
    
    convenience init(sampleBuffer: CMSampleBuffer, delegate: ViewControllerDelegate?) {
        // Create a CIImage from the buffer
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let image = CIImage(cvPixelBuffer: imageBuffer!)
        
        self.init(inputImage: image)
        
        self.delegate = delegate
    }
    
    func process() {
        // Detect any faces in the image
        let detector = CIDetector(ofType: CIDetectorTypeFace, context:nil, options:nil)
        var featureArgs = [String: AnyObject]()
        featureArgs[CIDetectorSmile] = true as AnyObject?
        let features = detector?.features(in: inputImage,options: featureArgs)
    
        
        // Build a masking image for each of the faces
        let maskImage: CIImage? = nil
        
        
        if features?.count == 0 {
            delegate?.updateRectangleFrame(CGRect.zero, emotion: emotion)
        }
        else {
            for feature in features! {
                //Check if feature is face
                if (feature.type == CIFeatureTypeFace) {
                    
                    self.originX = (feature.bounds.origin.x / 2.0) - (feature.bounds.size.width / 4.0) + 30
                    self.originY = UIScreen.main.bounds.height - feature.bounds.origin.y / 2.0 - feature.bounds.size.height / 2.0 - (feature.bounds.size.height / 2.0)
                    self.width = feature.bounds.size.width
                    self.height = feature.bounds.size.height
                    
                    let frame = CGRect(x: originX!, y: originY!, width: width!, height: height!)
                    if ((feature as! CIFaceFeature).hasSmile) {
                        emotion = "happy"
                        buffer = 8
                    }
                    delegate?.updateRectangleFrame(frame, emotion: emotion)
                    
                }
            }
        }
        
        // Create a single blended image made up of the pixellated image, the mask image, and the original image.
        // We want sections of the pixellated image to be removed according to the mask image, to reveal
        // the original image in the background.
        // We use the CIBlendWithMask filter for this, and set the background image as the original image,
        // the input image (the one to be masked) as the pixellated image, and the mask image as, well, the mask.
        var blendOptions = [String: AnyObject]()
        //blendOptions[kCIInputImageKey] = pixellatedImage
        blendOptions[kCIInputBackgroundImageKey] = inputImage
        blendOptions[kCIInputMaskImageKey] = maskImage
        let blend = CIFilter(name: "CIBlendWithMask", withInputParameters: blendOptions)
        
        // Finally, set the resulting image as the output
        outputImage = blend!.outputImage
    }
    
    
    fileprivate func recognizeImage(_ image: UIImage!) {
        // Scale down the image. This step is optional. However, sending large images over the
        // network is slow and does not significantly improve recognition performance.
        let size = CGSize(width: 320, height: 320 * image.size.height / image.size.width)
        UIGraphicsBeginImageContext(size)
        image.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        // Encode as a JPEG.
        let jpeg = UIImageJPEGRepresentation(scaledImage!, 0.9)!
        
        // Send the JPEG to Clarifai for standard image tagging.
        client.recognizeJpegs([jpeg]) {
            (results: [ClarifaiResult]?, error: NSError?) in
            if error != nil {
                //print("Error: \(error)\n")
            } else {
                for result in results! {
                    if (result == "joy"  || result == "happiness" || result == "smile" || result == "facial expression") {
                        self.emotion = "happy"
                        break
                    }
                }
            }
        }
    }
}

class ViewController: UIViewController, VideoFeedDelegate, ViewControllerDelegate {
    @IBOutlet weak var imageView: UIImageView!
    
    @IBOutlet weak var cameraButton: UIImageView!
    
    var feed: VideoFeed = VideoFeed()
    
//    var rectangle: UIView!
    
    var pikachu: UIImageView!
    
    override func awakeFromNib() {
        super.awakeFromNib()
        feed.delegate = self
        
        
        
        pikachu = UIImageView()
        pikachu.image = UIImage(named: "onix")
        view.addSubview(pikachu)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        startVideoFeed()
        
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        feed.stop()
        
    }
    
    override func viewDidLoad() {
        
    }
    
    
    func startVideoFeed() {
        do {
            try feed.start()
            print("Video started.")
            
        }
        catch {
            // alert?
            // need to look into device permissions
        }
        
    }
    
    func videoFeed(_ videoFeed: VideoFeed, didUpdateWithSampleBuffer sampleBuffer: CMSampleBuffer!) {
        if video_state == 0 {
            let filter = FaceObscurationFilter(sampleBuffer: sampleBuffer, delegate: self)
            filter.process()
            DispatchQueue.main.async(execute: { () -> Void in
                    self.imageView.image = UIImage(ciImage: filter.outputImage!)
            })
        }
    }
    
    

    
    func updateRectangleFrame(_ rect: CGRect, emotion: String) {
        DispatchQueue.main.async {
            self.pikachu.frame = rect
            if emotion == "happy" || buffer > 0 {
                self.pikachu.image = UIImage(named: "pikachu")
                buffer -= 1
            }
            else {
                self.pikachu.image = UIImage(named: "onix")
            }
         }
    }
    
    @IBAction func cameraButtonPressed(_ sender: UIButton) {
        
        let image = self.imageView.image!
        
        if let data = UIImagePNGRepresentation(image) {
            let filename = getDocumentsDirectory().appendingPathComponent("copy.png")
            try? data.write(to: URL(fileURLWithPath: filename), options: [.atomic])
        }
        else {
            print("error")
        }
        
        UIView.animate(withDuration: 0.5, animations: {
            self.imageView.alpha = 0.7
            }, completion: {
                (value: Bool) in
                self.imageView.alpha = 1.0
        })
        
        video_state = 1
        let seconds = 1
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(seconds) * Int64(NSEC_PER_SEC)) / Double(NSEC_PER_SEC)) {
            video_state = 0
        }
    }
    
    @IBAction func cameraChange(_ sender: UIButton) {
        camera_position = "back"
        // To be implemented
    }
    
    func getDocumentsDirectory() -> NSString {
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentsDirectory = paths[0]
        return documentsDirectory as NSString
    }
    
}

protocol ViewControllerDelegate {
    func updateRectangleFrame(_ rect: CGRect, emotion: String)
}
