import XCTest
import UIKit
@testable import Collector

final class CollectorGeometryTests:XCTestCase {
    @MainActor func testFinishedPolygonWithRemainingPredictionRequiresReview() {
        let store=CollectorStore()
        let polygon=Annotation(classID:0,x:10,y:10,width:20,height:20,points:[AnnotationPoint(x:10,y:10),AnnotationPoint(x:30,y:10),AnnotationPoint(x:20,y:30)])
        store.annotations=[polygon,Annotation(classID:0,x:40,y:40,width:20,height:20)]
        XCTAssertFalse(store.readyToApprove)
        XCTAssertTrue(store.approvalBlockReason?.contains("prediction rectangle") == true)
        store.annotations=[polygon]
        XCTAssertTrue(store.readyToApprove)
        store.addMode=true
        XCTAssertFalse(store.readyToApprove)
        store.cancelPolygon()
        XCTAssertTrue(store.readyToApprove)
        store.annotations=[]
        XCTAssertFalse(store.readyToApprove)
        store.explicitNegative=true
        XCTAssertTrue(store.readyToApprove)
    }
    func testPortraitLandscapeRoundTripAndClipping() throws {
        for source in [CGSize(width:240,height:320),CGSize(width:640,height:320),CGSize(width:4032,height:3024)] {
            let geometry=Letterbox(source)
            let input=Annotation(classID:4,x:geometry.offset.x,y:geometry.offset.y,width:geometry.rendered.width,height:geometry.rendered.height)
            let output=try XCTUnwrap(geometry.canonical(input))
            XCTAssertEqual(output.x,0,accuracy:0.0001);XCTAssertEqual(output.y,0,accuracy:0.0001)
            XCTAssertEqual(output.width,source.width,accuracy:0.0001);XCTAssertEqual(output.height,source.height,accuracy:0.0001)
        }
        XCTAssertNil(Annotation(classID:0,x:0,y:0,width:0,height:10).clipped(to:CGSize(width:100,height:100)))
        XCTAssertNil(Annotation(classID:0,x:.nan,y:0,width:10,height:10).clipped(to:CGSize(width:100,height:100)))
    }
    func testSameClassNMSRetainsBoxesAndOtherClasses() throws {
        var output=[Float](repeating:0,count:9*2100)
        func anchor(_ a:Int,_ c:Int,_ confidence:Float) {
            output[a]=160;output[2100+a]=160;output[4200+a]=40;output[6300+a]=60;output[(4+c)*2100+a]=confidence
        }
        anchor(0,0,0.9);anchor(1,0,0.8);anchor(2,4,0.95);anchor(3,2,0.49)
        let decoded=try decodeCollector(output,source:CGSize(width:320,height:320))
        XCTAssertEqual(decoded.count,2);XCTAssertEqual(Set(decoded.map(\.classID)),Set([0,4]))
        XCTAssertEqual(decoded[0].x,140);XCTAssertEqual(decoded[0].y,130);XCTAssertEqual(decoded[0].width,40)
    }
    func testRGBGrayPaddingAndTopLeftRows() throws {
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
        let image=UIGraphicsImageRenderer(size:CGSize(width:160,height:320),format:format).image {ctx in
            UIColor.red.setFill();ctx.fill(CGRect(x:0,y:0,width:160,height:160))
            UIColor.blue.setFill();ctx.fill(CGRect(x:0,y:160,width:160,height:160))
        }
        let pixels=try CollectorDetector.inputPixels(XCTUnwrap(image.cgImage))
        XCTAssertEqual(pixels[0],114/255,accuracy:0.005)
        let top=(10*320+100)*3,bottom=(300*320+100)*3
        XCTAssertEqual(pixels[top],1,accuracy:0.005);XCTAssertEqual(pixels[top+2],0,accuracy:0.005)
        XCTAssertEqual(pixels[bottom],0,accuracy:0.005);XCTAssertEqual(pixels[bottom+2],1,accuracy:0.005)
    }
    func testCanonicalEncodingNormalizesEXIFAndKeepsDimensions() throws {
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let raw=UIGraphicsImageRenderer(size:CGSize(width:80,height:120),format:format).image {ctx in UIColor.green.setFill();ctx.fill(CGRect(x:0,y:0,width:80,height:120))}
        let rotated=UIImage(cgImage:try XCTUnwrap(raw.cgImage),scale:1,orientation:.right)
        let (bytes,decoded)=try canonicalJPEG(rotated,maxDimension:4096,maxBytes:12582912)
        XCTAssertFalse(bytes.isEmpty);XCTAssertEqual(decoded.width,120);XCTAssertEqual(decoded.height,80)
        XCTAssertEqual(UIImage(data:bytes)?.imageOrientation,.up)
    }
    func testExactBundledModelLoadsAndRunsCPUContract() async throws {
        let detector=try CollectorDetector()
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let gray=UIGraphicsImageRenderer(size:CGSize(width:320,height:320),format:format).image {ctx in UIColor.gray.setFill();ctx.fill(CGRect(x:0,y:0,width:320,height:320))}
        let result=try await detector.infer(XCTUnwrap(gray.cgImage))
        XCTAssertTrue(result.allSatisfy {$0.rect.minX>=0 && $0.rect.maxX<=320 && $0.width>0})
    }
}
