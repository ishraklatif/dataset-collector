import UIKit
import CryptoKit
import TensorFlowLiteC

// Interpreter access is serialized by queue; initialization completes before publication.
final class CollectorDetector:@unchecked Sendable {
    private let model:OpaquePointer
    private let interpreter:OpaquePointer
    private let queue=DispatchQueue(label:"collector.inference",qos:.userInitiated)
    init() throws {
        guard let url=Bundle.main.url(forResource:"yolo11n-seg-trained-v1",withExtension:"tflite") else {throw CollectorError.message("Bundled model missing")}
        let hash=SHA256.hash(data:try Data(contentsOf:url)).map {String(format:"%02x",$0)}.joined()
        guard hash==collectorModelHash else {throw CollectorError.message("Bundled model checksum mismatch")}
        guard let m=TfLiteModelCreateFromFile(url.path),let options=TfLiteInterpreterOptionsCreate() else {throw CollectorError.message("Model loading failed")}
        TfLiteInterpreterOptionsSetNumThreads(options,2)
        guard let i=TfLiteInterpreterCreate(m,options) else {TfLiteInterpreterOptionsDelete(options);TfLiteModelDelete(m);throw CollectorError.message("Interpreter creation failed")}
        TfLiteInterpreterOptionsDelete(options);model=m;interpreter=i
        guard TfLiteInterpreterAllocateTensors(i)==kTfLiteOk else {throw CollectorError.message("Tensor allocation failed")}
        try Self.validate(TfLiteInterpreterGetInputTensor(i,0).map { UnsafePointer($0) },shape:[1,320,320,3])
        // Two outputs: detections+mask-coefficients [1,41,2100] and NHWC mask prototypes [1,80,80,32].
        // Order is not guaranteed by index, so match by shape rather than assuming output 0/1.
        let out0=TfLiteInterpreterGetOutputTensor(i,0),out1=TfLiteInterpreterGetOutputTensor(i,1)
        guard let out0,let out1 else {throw CollectorError.message("Actual model tensor contract differs")}
        if (try? Self.validate(out0,shape:[1,41,2100])) != nil {
            try Self.validate(out1,shape:[1,80,80,32]);mainOutputIndex=0;protoOutputIndex=1
        } else {
            try Self.validate(out0,shape:[1,80,80,32]);try Self.validate(out1,shape:[1,41,2100]);mainOutputIndex=1;protoOutputIndex=0
        }
        var input=[Float](repeating:114/255,count:320*320*3)
        try setInput(&input)
        let probe=try output(index:mainOutputIndex,count:41*2100)
        guard probe.prefix(4*2100).allSatisfy(\.isFinite),(probe.prefix(4*2100).max() ?? 0)>2 else {throw CollectorError.message("Model coordinate units require verification")}
    }
    private let mainOutputIndex:Int32
    private let protoOutputIndex:Int32
    deinit {TfLiteInterpreterDelete(interpreter);TfLiteModelDelete(model)}
    private static func validate(_ tensor:UnsafePointer<TfLiteTensor>?,shape:[Int32]) throws {
        guard let tensor,TfLiteTensorType(tensor)==kTfLiteFloat32,TfLiteTensorNumDims(tensor)==shape.count,
              shape.enumerated().allSatisfy({TfLiteTensorDim(tensor,Int32($0.offset))==$0.element}) else {throw CollectorError.message("Actual model tensor contract differs")}
    }
    private func setInput(_ values:inout [Float]) throws {
        let status=values.withUnsafeBytes {TfLiteTensorCopyFromBuffer(TfLiteInterpreterGetInputTensor(interpreter,0),$0.baseAddress,$0.count)}
        guard status==kTfLiteOk,TfLiteInterpreterInvoke(interpreter)==kTfLiteOk else {throw CollectorError.message("Inference failed")}
    }
    private func output(index:Int32,count:Int) throws ->[Float] {
        var values=[Float](repeating:0,count:count)
        let status=values.withUnsafeMutableBytes {TfLiteTensorCopyToBuffer(TfLiteInterpreterGetOutputTensor(interpreter,index),$0.baseAddress,$0.count)}
        guard status==kTfLiteOk else {throw CollectorError.message("Output copying failed")}
        return values
    }
    static func inputPixels(_ image:CGImage) throws ->[Float] {
        let geometry=Letterbox(CGSize(width:image.width,height:image.height))
        var rgba=[UInt8](repeating:0,count:320*320*4)
        let drawn:Bool=rgba.withUnsafeMutableBytes {buffer in
            guard let context=CGContext(data:buffer.baseAddress,width:320,height:320,bitsPerComponent:8,bytesPerRow:320*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {return false}
            context.setFillColor(red:114/255,green:114/255,blue:114/255,alpha:1);context.fill(CGRect(x:0,y:0,width:320,height:320))
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(origin:geometry.offset,size:geometry.rendered))
            return true
        }
        guard drawn else {throw CollectorError.message("Unable to preprocess image")}
        var rgb=[Float](repeating:0,count:320*320*3)
        for p in 0..<(320*320) {for c in 0..<3 {rgb[p*3+c]=Float(rgba[p*4+c])/255}}
        return rgb
    }
    func infer(_ image:CGImage) async throws ->[Annotation] {
        try await withCheckedThrowingContinuation {continuation in
            queue.async {
                do {
                    var pixels=try Self.inputPixels(image);try self.setInput(&pixels)
                    let main=try self.output(index:self.mainOutputIndex,count:41*2100)
                    let proto=try self.output(index:self.protoOutputIndex,count:80*80*32)
                    let boxes=try decodeCollector(main,proto:proto,source:CGSize(width:image.width,height:image.height))
                    continuation.resume(returning:boxes)
                } catch {continuation.resume(throwing:error)}
            }
        }
    }
}
