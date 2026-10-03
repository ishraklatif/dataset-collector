import Foundation
import CoreGraphics

let collectorClasses = ["collection_tube", "kit_package", "reply_paid_envelope", "toilet_liner", "ziplock_bag"]
let collectorModelHash = "455888c9b0bc769b0a6307c324ed59879b706cab6283742d9f5aaf7097bf4937"
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
}

// Port of the reference decoder: channel-major [1,9,2100], argmax and same-class NMS.
// Keep geometry for human review and reverse the exact still-image letterbox.
func decodeCollector(_ values: [Float],source: CGSize) throws -> [Annotation] {
    guard values.count==9*2100 else { throw CollectorError.message("Unexpected model output") }
    let geometry=Letterbox(source)
    var candidates:[Annotation]=[]
    for a in 0..<2100 {
        let scores=(0..<5).map { values[(4+$0)*2100+a] }
        guard let best=scores.indices.filter({ scores[$0].isFinite }).max(by:{ scores[$0]<scores[$1] }), scores[best]>=0.5 else { continue }
        let cx=Double(values[a]),cy=Double(values[2100+a]),w=Double(values[4200+a]),h=Double(values[6300+a])
        if [cx,cy,w,h].allSatisfy(\.isFinite), w>0, h>0 {
            candidates.append(Annotation(classID:best,x:cx-w/2,y:cy-h/2,width:w,height:h,confidence:Double(scores[best])))
        }
    }
    func iou(_ a:CGRect,_ b:CGRect)->Double {
        let r=a.intersection(b); let area=r.isNull ? 0:r.width*r.height
        let union=a.width*a.height+b.width*b.height-area
        return union>0 ? area/union:0
    }
    var kept:[Annotation]=[]
    for c in 0..<5 {
        var accepted:[Annotation]=[]
        for b in candidates.filter({$0.classID==c}).sorted(by:{($0.confidence ?? 0)>($1.confidence ?? 0)}) {
            if !accepted.contains(where:{iou($0.rect,b.rect)>0.45}) { accepted.append(b) }
        }
        kept += accepted.compactMap { geometry.canonical($0) }
    }
    return Array(kept.prefix(200))
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
