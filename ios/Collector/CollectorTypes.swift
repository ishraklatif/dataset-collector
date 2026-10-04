import Foundation
import CoreGraphics

let collectorClasses = ["collection_tube", "kit_package", "reply_paid_envelope", "toilet_liner", "ziplock_bag"]
let collectorModelHash = "dd65049a00a545d1744f693afc611931c7bb4e470c4248d8072c1fc2e168913c"
let collectorPreprocessing = "upright-jpeg-rgb-contain-gray114-v1"

struct AnnotationPoint:Codable,Equatable {
    var x:Double
    var y:Double
    init(x:Double,y:Double) {self.x=x;self.y=y}
    init(_ point:CGPoint) {x=Double(point.x);y=Double(point.y)}
    var cgPoint:CGPoint {CGPoint(x:x,y:y)}
}

struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var classID: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var points:[AnnotationPoint]? = nil
    var confidence: Double?
    enum CodingKeys: String, CodingKey { case classID = "class_id", x, y, width, height, points, confidence }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var label: String { collectorClasses.indices.contains(classID) ? collectorClasses[classID] : "Unknown" }
    func clipped(to size: CGSize) -> Annotation? {
        guard collectorClasses.indices.contains(classID), [x,y,width,height].allSatisfy(\.isFinite), width>0, height>0 else { return nil }
        let r = rect.intersection(CGRect(origin:.zero,size:size))
        guard !r.isNull, r.width>0, r.height>0 else { return nil }
        var b = self; b.x=r.minX; b.y=r.minY; b.width=r.width; b.height=r.height
        return b
    }
    var human: Annotation { var b=self; b.confidence=nil; return b }
}

struct Letterbox {
    let source: CGSize
    let rendered: CGSize
    let offset: CGPoint
    init(_ source: CGSize) {
        self.source=source
        let scale=min(320/source.width,320/source.height)
        rendered=CGSize(width:(source.width*scale).rounded(),height:(source.height*scale).rounded())
        offset=CGPoint(x:floor((320-rendered.width)/2),y:floor((320-rendered.height)/2))
    }
    func canonical(_ b: Annotation) -> Annotation? {
        var value=b
        value.x=(b.x-offset.x)*source.width/rendered.width
        value.y=(b.y-offset.y)*source.height/rendered.height
        value.width=b.width*source.width/rendered.width
        value.height=b.height*source.height/rendered.height
        return value.clipped(to:source)
    }
    // Reverses the same still-image letterbox for a polygon's points (not just a box),
    // clamping each point into the source image bounds independently - domain.py's
    // server-side validation already requires every point within [0,width]x[0,height].
    func canonicalPoints(_ points:[CGPoint])->[CGPoint] {
        points.map {p in
            let x=(p.x-offset.x)*source.width/rendered.width
            let y=(p.y-offset.y)*source.height/rendered.height
            return CGPoint(x:min(max(x,0),source.width),y:min(max(y,0),source.height))
        }
    }
}

// Decodes a yolo11n-seg output: channel-major main tensor [1,41,2100] (4 box
// + 5 class scores + 32 mask coefficients per anchor) plus the shared NHWC
// prototype tensor [1,80,80,32]. Same argmax/confidence gate and same-class
// NMS as the former plain-detector decoder, but each surviving detection's
// mask coefficients are combined with the prototypes (CollectorSegmentation)
// into a traced, simplified outline - so proposals arrive as draft polygons,
// not boxes, directly usable in BoxEditor's existing polygon editing tools.
private struct DetectionCandidate {
    let classID:Int
    let confidence:Double
    let box:CGRect
    let coeffs:[Float]
}
func decodeCollector(_ main:[Float],proto:[Float],source:CGSize) throws -> [Annotation] {
    guard main.count==41*2100 else { throw CollectorError.message("Unexpected model output") }
    guard proto.count==80*80*32 else { throw CollectorError.message("Unexpected model output") }
    let geometry=Letterbox(source)
    var candidates:[DetectionCandidate]=[]
    for a in 0..<2100 {
        let scores=(0..<5).map { main[(4+$0)*2100+a] }
        guard let best=scores.indices.filter({ scores[$0].isFinite }).max(by:{ scores[$0]<scores[$1] }), scores[best]>=0.5 else { continue }
        let cx=Double(main[a]),cy=Double(main[2100+a]),w=Double(main[4200+a]),h=Double(main[6300+a])
        guard [cx,cy,w,h].allSatisfy(\.isFinite), w>0, h>0 else { continue }
        let coeffs=(0..<32).map { main[(9+$0)*2100+a] }
        candidates.append(DetectionCandidate(classID:best,confidence:Double(scores[best]),box:CGRect(x:cx-w/2,y:cy-h/2,width:w,height:h),coeffs:coeffs))
    }
    func iou(_ a:CGRect,_ b:CGRect)->Double {
        let r=a.intersection(b); let area=r.isNull ? 0:r.width*r.height
        let union=a.width*a.height+b.width*b.height-area
        return union>0 ? area/union:0
    }
    var kept:[DetectionCandidate]=[]
    for c in 0..<5 {
        var accepted:[DetectionCandidate]=[]
        for cand in candidates.filter({$0.classID==c}).sorted(by:{$0.confidence>$1.confidence}) {
            if !accepted.contains(where:{iou($0.box,cand.box)>0.45}) { accepted.append(cand) }
        }
        kept += accepted
    }
    kept = Array(kept.prefix(200))

    var results:[Annotation]=[]
    for cand in kept {
        guard let maskPoints=CollectorSegmentation.polygon(coeffs:cand.coeffs,proto:proto) else { continue }
        let canonicalPoints=geometry.canonicalPoints(maskPoints)
        let xs=canonicalPoints.map(\.x),ys=canonicalPoints.map(\.y)
        guard let left=xs.min(),let right=xs.max(),let top=ys.min(),let bottom=ys.max(),right>left,bottom>top else { continue }
        let points=canonicalPoints.map {AnnotationPoint(x:Double($0.x),y:Double($0.y))}
        // Model outlines are only suggestions. A malformed mask contour must not
        // prevent the photo from being uploaded for manual annotation in review.
        guard isUploadableProposal(points) else { continue }
        results.append(Annotation(classID:cand.classID,x:Double(left),y:Double(top),width:Double(right-left),height:Double(bottom-top),points:points,confidence:cand.confidence))
    }
    return results
}

private func isUploadableProposal(_ points:[AnnotationPoint])->Bool {
    guard (3...256).contains(points.count),Set(points.map {"\($0.x),\($0.y)"}).count>=3 else {return false}
    let area=points.indices.reduce(0.0) {sum,i in
        let a=points[i],b=points[(i+1)%points.count]
        return sum+a.x*b.y-b.x*a.y
    }
    guard area.isFinite,abs(area)>1e-6 else {return false}
    func orient(_ a:AnnotationPoint,_ b:AnnotationPoint,_ c:AnnotationPoint)->Double {
        (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
    }
    func onSegment(_ a:AnnotationPoint,_ b:AnnotationPoint,_ c:AnnotationPoint)->Bool {
        min(a.x,b.x)-1e-9<=c.x && c.x<=max(a.x,b.x)+1e-9 && min(a.y,b.y)-1e-9<=c.y && c.y<=max(a.y,b.y)+1e-9
    }
    func intersects(_ a:AnnotationPoint,_ b:AnnotationPoint,_ c:AnnotationPoint,_ d:AnnotationPoint)->Bool {
        let o1=orient(a,b,c),o2=orient(a,b,d),o3=orient(c,d,a),o4=orient(c,d,b)
        return (o1*o2<0 && o3*o4<0) || (abs(o1)<1e-9 && onSegment(a,b,c)) || (abs(o2)<1e-9 && onSegment(a,b,d)) || (abs(o3)<1e-9 && onSegment(c,d,a)) || (abs(o4)<1e-9 && onSegment(c,d,b))
    }
    for i in points.indices {
        let a=points[i],b=points[(i+1)%points.count]
        for j in points.indices where j>i {
            if j==i || j==(i+1)%points.count || (j+1)%points.count==i {continue}
            if intersects(a,b,points[j],points[(j+1)%points.count]) {return false}
        }
    }
    return true
}

enum CollectorError:LocalizedError {
    case message(String)
    case http(Int,String)
    var errorDescription:String? { switch self { case .message(let s):return s;case .http(let code,let s):return s+" (\(code))" } }
}
struct Project:Codable,Identifiable { let id:String; let name:String }
struct Health:Codable { let projects:[Project]; let max_image_bytes:Int; let max_image_dimension:Int; let model_hash:String; let annotation_format:String?; let db_bytes_used:Int?; let db_byte_limit:Int?; let needs_archive:Bool? }
struct CaptureSession:Codable,Identifiable { let id:String; let name:String; let specimen_name:String; let designation:String }
struct SampleSummary:Codable,Identifiable {
    let id:String; let session_id:String; let current_revision:String; let status:String
    let explicit_negative:Bool; let width:Int; let height:Int; let archived_at:String?; let class_ids:[Int]?
    var labels:String {
        let names=(class_ids ?? []).compactMap {collectorClasses.indices.contains($0) ? collectorClasses[$0]:nil}
        if names.isEmpty {return explicit_negative ? "No objects":"Unlabeled"}
        return names.joined(separator:", ")
    }
}
struct SampleDetail:Codable {
    let id:String; let current_revision:String; let status:String; let explicit_negative:Bool
    let annotations:[Annotation]; let proposals:[Annotation]; let width:Int; let height:Int; let archived_at:String?
}
struct SamplePage:Codable {
    struct Count:Codable { let status:String; let count:Int }
    struct ClassCount:Codable { let class_id:Int; let instances:Int; let images:Int }
    let samples:[SampleSummary]; let counts:[Count]; let classes:[ClassCount]; let next_offset:Int?
}
struct DatasetVersion:Codable,Identifiable { let id:String; let samples:Int; let status:String; let drive_link:String? }
struct ArchiveResult:Decodable {
    let version:String; let job_id:String; let samples:Int; let drive_link:String?; let bytes_freed:Int; let warnings:[String]
}
