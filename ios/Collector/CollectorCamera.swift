import AVFoundation
import UIKit
import SwiftUI

// Camera/session state and continuations are confined to queue. Published state is written on main.
final class CollectorCamera:NSObject,ObservableObject,AVCapturePhotoCaptureDelegate,AVCaptureVideoDataOutputSampleBufferDelegate,@unchecked Sendable {
    let session=AVCaptureSession()
    private let photoOutput=AVCapturePhotoOutput()
    private let videoOutput=AVCaptureVideoDataOutput()
    private let queue=DispatchQueue(label:"collector.camera",qos:.userInitiated)
    private var configured=false
    private var active=false
    private var frameCount=0
    private var liveBusy=false
    private var captureContinuation:CheckedContinuation<UIImage,Error>?
    private var detector:CollectorDetector?
    func setDetector(_ value:CollectorDetector) {queue.async {self.detector=value}}
    private var observers:[NSObjectProtocol]=[]
    @Published var available=false
    @Published var problem:String?
    @Published var liveBoxes:[Annotation]=[]
    @Published var liveSize=CGSize(width:1,height:1)
    override init() {
        super.init()
        for name in [Notification.Name.AVCaptureSessionRuntimeError,Notification.Name.AVCaptureSessionWasInterrupted] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:session,queue:nil) { [weak self] _ in
                guard let self else {return}
                self.queue.async {
                    self.active=false
                    let continuation=self.captureContinuation;self.captureContinuation=nil
                    continuation?.resume(throwing:CollectorError.message("Camera was interrupted; retry capture"))
                    DispatchQueue.main.async {self.available=false;self.problem="Camera unavailable or interrupted. Return to the app to retry.";self.liveBoxes=[]}
                }
            })
        }
    }
    deinit {observers.forEach {NotificationCenter.default.removeObserver($0)}}
    func start() async {
        let granted=await AVCaptureDevice.requestAccess(for:.video)
        guard granted else {await MainActor.run {self.problem="Camera permission denied. Enable it in Settings."};return}
        queue.async {
            do {
                if !self.configured {
                    guard let device=AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back) else {throw CollectorError.message("Rear camera unavailable")}
                    self.session.beginConfiguration()
                    do {
                        self.session.sessionPreset = .photo
                        let input=try AVCaptureDeviceInput(device:device)
                        guard self.session.canAddInput(input),self.session.canAddOutput(self.photoOutput),self.session.canAddOutput(self.videoOutput) else {throw CollectorError.message("Camera outputs unavailable")}
                        self.session.addInput(input);self.session.addOutput(self.photoOutput);self.session.addOutput(self.videoOutput)
                        self.videoOutput.alwaysDiscardsLateVideoFrames=true
                        self.videoOutput.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
                        self.videoOutput.setSampleBufferDelegate(self,queue:self.queue)
                    } catch {
                        self.session.commitConfiguration()
                        throw error
                    }
                    self.session.commitConfiguration()
                    self.configured=true
                }
                self.active=true
                if !self.session.isRunning {self.session.startRunning()}
                DispatchQueue.main.async {self.available=true;self.problem=nil}
            } catch {DispatchQueue.main.async {self.problem=error.localizedDescription;self.available=false}}
        }
    }
    func stop() {
        queue.async {self.active=false;if self.session.isRunning {self.session.stopRunning()}}
        DispatchQueue.main.async {self.liveBoxes=[];self.available=false}
    }
    func capture() async throws ->UIImage {
        try await withCheckedThrowingContinuation {continuation in
            queue.async {
                guard self.configured,self.session.isRunning,self.captureContinuation==nil else {continuation.resume(throwing:CollectorError.message("Camera is not ready"));return}
                self.captureContinuation=continuation
                // Portrait canonical orientation is fixed for the app. Device rotation changes
                // the scene, not the saved orientation contract. No file-output APIs are used.
                self.photoOutput.connection(with:.video)?.videoOrientation = .portrait
                let settings=AVCapturePhotoSettings(format:[AVVideoCodecKey:AVVideoCodecType.jpeg])
                settings.flashMode = .off
                self.photoOutput.capturePhoto(with:settings,delegate:self)
            }
        }
    }
    func photoOutput(_ output:AVCapturePhotoOutput,didFinishProcessingPhoto photo:AVCapturePhoto,error:Error?) {
        queue.async {
            guard let continuation=self.captureContinuation else {return}
            self.captureContinuation=nil
            if let error {continuation.resume(throwing:error);return}
            guard let data=photo.fileDataRepresentation(),let image=UIImage(data:data) else {continuation.resume(throwing:CollectorError.message("Photo decoding failed"));return}
            continuation.resume(returning:image)
        }
    }
    func photoOutput(_ output:AVCapturePhotoOutput,didFinishCaptureFor resolvedSettings:AVCaptureResolvedPhotoSettings,error:Error?) {
        if let error {queue.async {let c=self.captureContinuation;self.captureContinuation=nil;c?.resume(throwing:error)}}
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        frameCount+=1
        guard active,frameCount%10==0,!liveBusy,captureContinuation==nil,let detector,let pixels=CMSampleBufferGetImageBuffer(sampleBuffer) else {return}
        liveBusy=true
        // Live frames are proposals only; capture inference always uses the exact canonical JPEG.
        let ci=CIImage(cvPixelBuffer:pixels).oriented(.right)
        guard let cg=CIContext(options:[.cacheIntermediates:false]).createCGImage(ci,from:ci.extent) else {liveBusy=false;return}
        Task {
            do {
                let boxes=try await detector.infer(cg)
                self.queue.async {let running=self.active;self.liveBusy=false;if running {DispatchQueue.main.async {self.liveBoxes=boxes;self.liveSize=CGSize(width:cg.width,height:cg.height)}}}
            } catch {self.queue.async {self.liveBusy=false};await MainActor.run {self.problem="Live inference: "+error.localizedDescription}}
        }
    }
}

struct CameraPreview:UIViewRepresentable {
    let camera:CollectorCamera
    func makeUIView(context:Context)->PreviewView {
        let view=PreviewView();view.preview.session=camera.session;view.preview.videoGravity = .resizeAspect
        view.preview.connection?.videoOrientation = .portrait
        return view
    }
    func updateUIView(_ view:PreviewView,context:Context) {}
    final class PreviewView:UIView {
        override class var layerClass:AnyClass {AVCaptureVideoPreviewLayer.self}
        var preview:AVCaptureVideoPreviewLayer {layer as! AVCaptureVideoPreviewLayer}
    }
}

func canonicalJPEG(_ image:UIImage,maxDimension:Int,maxBytes:Int) throws ->(Data,CGImage) {
    let original=image.size
    let scale=min(1,CGFloat(maxDimension)/max(original.width,original.height))
    let size=CGSize(width:(original.width*scale).rounded(),height:(original.height*scale).rounded())
    let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
    let upright=UIGraphicsImageRenderer(size:size,format:format).image {_ in image.draw(in:CGRect(origin:.zero,size:size))}
    // Drawing creates upright pixels without EXIF/GPS. Encode once, decode those exact bytes,
    // and infer on that decoded image so JPEG compression is included in the contract.
    guard let data=upright.jpegData(compressionQuality:0.92),data.count<=maxBytes,let decoded=UIImage(data:data)?.cgImage else {throw CollectorError.message("Photo exceeds server byte limit; increase the limit or review capture resolution")}
    return (data,decoded)
}
