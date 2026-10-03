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
        var main=[Float](repeating:0,count:41*2100)
        func anchor(_ a:Int,_ c:Int,_ confidence:Float) {
            main[a]=160;main[2100+a]=160;main[4200+a]=40;main[6300+a]=60;main[(4+c)*2100+a]=confidence
            main[9*2100+a]=10 // strong positive coefficient on prototype channel 0
        }
        anchor(0,0,0.9);anchor(1,0,0.8);anchor(2,4,0.95);anchor(3,2,0.49)
        // Prototype channel 0 is uniformly positive everywhere, so every surviving
        // detection decodes to a full-frame mask regardless of its regressed box -
        // this test is about NMS dedup/class-retention, not mask shape fidelity
        // (that's covered by testContourTraceAndSimplifyOnSyntheticMask below).
        var proto=[Float](repeating:0,count:80*80*32)
        for cell in 0..<(80*80) {proto[cell*32]=1}
        let decoded=try decodeCollector(main,proto:proto,source:CGSize(width:320,height:320))
        XCTAssertEqual(decoded.count,2);XCTAssertEqual(Set(decoded.map(\.classID)),Set([0,4]))
        XCTAssertTrue(decoded.allSatisfy {($0.points?.count ?? 0)>=3})
    }
    func testContourTraceAndSimplifyOnSyntheticMask() throws {
        // A 40x40 filled square at (100,100)-(140,140) inside a 320x320 mask.
        var mask=[Bool](repeating:false,count:320*320)
        for y in 100..<140 {for x in 100..<140 {mask[y*320+x]=true}}
        let contour=try XCTUnwrap(CollectorSegmentation.traceContour(mask,width:320,height:320))
        XCTAssertTrue(contour.count>=4)
        let xs=contour.map(\.x),ys=contour.map(\.y)
        XCTAssertEqual(xs.min() ?? -1,100,accuracy:1);XCTAssertEqual(xs.max() ?? -1,139,accuracy:1)
        XCTAssertEqual(ys.min() ?? -1,100,accuracy:1);XCTAssertEqual(ys.max() ?? -1,139,accuracy:1)
        let simplified=CollectorSegmentation.simplifyToLimit(contour,maxPoints:16)
        XCTAssertTrue(simplified.count>=4 && simplified.count<=16)
        let sxs=simplified.map(\.x),sys=simplified.map(\.y)
        XCTAssertEqual(sxs.min() ?? -1,100,accuracy:2);XCTAssertEqual(sxs.max() ?? -1,139,accuracy:2)
        XCTAssertEqual(sys.min() ?? -1,100,accuracy:2);XCTAssertEqual(sys.max() ?? -1,139,accuracy:2)
    }
    func testContourTraceReturnsNilForEmptyMask() {
        XCTAssertNil(CollectorSegmentation.traceContour([Bool](repeating:false,count:100),width:10,height:10))
    }
    func testPolygonFromMaskCombinesCoefficientsAndPrototypes() throws {
        var proto=[Float](repeating:0,count:80*80*32)
        for cell in 0..<(80*80) {proto[cell*32]=1}
        let coeffs=[Float](repeating:0,count:32).enumerated().map {$0.offset==0 ? Float(10):0}
        let polygon=try XCTUnwrap(CollectorSegmentation.polygon(coeffs:coeffs,proto:proto))
        XCTAssertTrue(polygon.count>=3)
        // Strongly-positive channel-0 coefficient against an all-ones channel-0
        // prototype should yield a full-frame mask (traced corners near the edges).
        let xs=polygon.map(\.x),ys=polygon.map(\.y)
        XCTAssertEqual(xs.min() ?? -1,0,accuracy:1);XCTAssertEqual(ys.min() ?? -1,0,accuracy:1)
        XCTAssertEqual(xs.max() ?? -1,319,accuracy:1);XCTAssertEqual(ys.max() ?? -1,319,accuracy:1)
    }
    func testLetterboxCanonicalPointsMatchesRectTransformAndClamps() {
        let source=CGSize(width:640,height:320)
        let geometry=Letterbox(source)
        let corners=[CGPoint(x:geometry.offset.x,y:geometry.offset.y),
                     CGPoint(x:geometry.offset.x+geometry.rendered.width,y:geometry.offset.y+geometry.rendered.height)]
        let mapped=geometry.canonicalPoints(corners)
        XCTAssertEqual(mapped[0].x,0,accuracy:0.01);XCTAssertEqual(mapped[0].y,0,accuracy:0.01)
        XCTAssertEqual(mapped[1].x,source.width,accuracy:0.01);XCTAssertEqual(mapped[1].y,source.height,accuracy:0.01)
        // Out-of-frame input (e.g. a mask touching the letterbox padding) clamps into bounds.
        let outOfBounds=geometry.canonicalPoints([CGPoint(x:-50,y:-50),CGPoint(x:10000,y:10000)])
        XCTAssertEqual(outOfBounds[0].x,0);XCTAssertEqual(outOfBounds[0].y,0)
        XCTAssertEqual(outOfBounds[1].x,source.width);XCTAssertEqual(outOfBounds[1].y,source.height)
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
        // A flat gray probe image should trigger no real detections; the meaningful
        // assertion is that the two-output segmentation model loads, runs end to
        // end, and any result it does produce is already a polygon proposal.
        XCTAssertTrue(result.allSatisfy {$0.rect.minX>=0 && $0.rect.maxX<=320 && $0.width>0 && ($0.points?.count ?? 0)>=3})
    }
}
