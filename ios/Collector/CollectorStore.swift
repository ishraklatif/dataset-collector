import SwiftUI
import CryptoKit
import Combine
import Network

@MainActor final class CollectorStore:ObservableObject {
    let api=CollectorAPI()
    let camera=CollectorCamera()
    @Published var endpoint=UserDefaults.standard.string(forKey:"collectorEndpoint") ?? ""
    @Published var username=""
    @Published var password=""
    @Published var connected=false
    @Published var busy=false
    @Published var message="Configure a backend to begin. Captures require connectivity."
    @Published var health:Health?
    @Published var project:String=""
    @Published var sessions:[CaptureSession]=[]
    @Published var sessionID:String=""
    @Published var samples:[SampleSummary]=[]
    @Published var versions:[DatasetVersion]=[]
    @Published var page:SamplePage?
    @Published var selected:UUID?
    @Published var annotations:[Annotation]=[]
    @Published var polygonDraft:[AnnotationPoint]=[]
    @Published var explicitNegative=false
    @Published var review:SampleDetail?
    @Published var image:UIImage?
    @Published var edited=false
    @Published var addMode=false
    @Published var addVertexMode=false
    @Published var shareURL:URL?
    @Published var archivePrompt=false
    private var archiveAlertShown=false
    @Published var sessionName=""
    @Published var specimenName=""
    @Published var designation="proxy"
    @Published var tags=""
    @Published var detectorReady=false
    private var detector:CollectorDetector?
    private var cameraSubscription:AnyCancellable?
    private let connectivity=NWPathMonitor()
    private var undoHistory:[[Annotation]]=[]
    private struct Pending {let id:String;let bytes:Data;let metadata:Data}
    private var pending:Pending?
    var hasPending:Bool {pending != nil}
    var canCapture:Bool {connected && detectorReady && !sessionID.isEmpty && review==nil && pending==nil && !busy && camera.available}
    var editable:Bool {connected && review?.status=="pending_review" && !busy}
    var approvalBlockReason:String? {
        if addMode {return "Finish or cancel the polygon you are drawing before saving."}
        if annotations.contains(where:{$0.points==nil}) {return "Select each remaining prediction rectangle and convert it to a polygon, or delete it if incorrect. You can save a draft now."}
        if annotations.contains(where:{($0.points?.count ?? 0)<3}) {return "Each polygon needs at least three points before approval."}
        if annotations.isEmpty && !explicitNegative {return "Add an object polygon, or confirm that no target objects are present."}
        return nil
    }
    var readyToApprove:Bool {approvalBlockReason==nil}
    var storageWarning:String? {
        guard let used=health?.db_bytes_used,let limit=health?.db_byte_limit,limit>0,Double(used)/Double(limit)>=0.8 else {return nil}
        let formatter=ByteCountFormatter();formatter.countStyle = .binary
        return "Database storage is \(Int(Double(used)/Double(limit)*100))% full (\(formatter.string(fromByteCount:Int64(used))) of \(formatter.string(fromByteCount:Int64(limit)))). Export and archive approved samples soon."
    }

    init() {
        cameraSubscription=camera.objectWillChange.sink {[weak self] in self?.objectWillChange.send()}
        connectivity.pathUpdateHandler={[weak self] path in
            if path.status == .unsatisfied {Task {@MainActor in
                guard let self,self.connected else {return}
                self.connected=false;self.message="Offline. Collection and review are paused; server-confirmed samples remain in Neon."
            }}
        }
        connectivity.start(queue:DispatchQueue(label:"collector.connectivity"))
    }

    func initialize() async {
        // Unit tests create their own model and image fixtures; do not start hardware capture.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {return}
        do {
            let detector:CollectorDetector=try await withCheckedThrowingContinuation {continuation in
                DispatchQueue.global(qos:.userInitiated).async {do {continuation.resume(returning:try CollectorDetector())} catch {continuation.resume(throwing:error)}}
            }
            self.detector=detector;camera.setDetector(detector);detectorReady=true
        } catch {message="Model error: "+error.localizedDescription}
        if !endpoint.isEmpty {do {try api.configure(endpoint);if api.token != nil {await refreshConnection()}} catch {message=error.localizedDescription}}
        await camera.start()
    }
    func perform(_ work:() async throws ->Void) async {
        guard !busy else {return};busy=true
        do {try await work()} catch {
            if error is URLError {connected=false}
            if case CollectorError.http(let code,_)=error,code==401 || code>=500 {connected=false}
            message=error.localizedDescription
        }
        busy=false
    }
    func signIn() async {
        await perform {
            try api.configure(endpoint);try await api.login(username:username,password:password)
            password="";try await reload();message="Connected. Choose a session or create one."
        }
    }
    func signOut() async {
        await perform {
            _=try await api.request("/v1/logout",method:"POST")
            try CollectorKeychain.store(nil);api.token=nil;connected=false;health=nil;project="";sessionID=""
            sessions=[];samples=[];versions=[];page=nil;clearReview();pending=nil;message="Signed out. Unacknowledged RAM captures are released."
        }
    }
    func refreshConnection() async {
        guard !busy else {return}
        do {
            try await reload()
            if message == "Configure a backend to begin. Captures require connectivity." || message.hasPrefix("Collection paused:") {
                message="Connected. Choose a session or create one."
            }
        } catch {connected=false;message="Collection paused: "+error.localizedDescription}
    }
    private func reload() async throws {
        let h=try await api.get("/v1/health",as:Health.self)
        guard h.model_hash==collectorModelHash else {throw CollectorError.message("Backend model does not match this app")}
        guard h.annotation_format=="yolo-segmentation-v1" else {throw CollectorError.message("Collector backend needs the polygon segmentation update before this app can save outlines")}
        health=h;connected=true
        if h.needs_archive==true {if !archiveAlertShown {archivePrompt=true;archiveAlertShown=true}} else {archiveAlertShown=false}
        if !h.projects.contains(where:{$0.id==project}) {project=h.projects.first?.id ?? ""}
        guard !project.isEmpty else {throw CollectorError.message("No authorized collector project")}
        struct Sessions:Decodable {let sessions:[CaptureSession]}
        sessions=try await api.get("/v1/projects/\(project)/sessions",as:Sessions.self).sessions
        if !sessions.contains(where:{$0.id==sessionID}) {sessionID=""}
        let p=try await api.get("/v1/projects/\(project)/samples",as:SamplePage.self);page=p;samples=p.samples
        struct Versions:Decodable {let versions:[DatasetVersion]}
        versions=try await api.get("/v1/projects/\(project)/versions",as:Versions.self).versions
    }
    func loadMore() async {
        guard let offset=page?.next_offset else {return}
        await perform {let p=try await api.get("/v1/projects/\(project)/samples?offset=\(offset)",as:SamplePage.self);page=p;samples+=p.samples}
    }
    func createSession() async {
        await perform {
            let body:[String:Any]=["name":sessionName,"specimen":specimenName,"designation":designation,"device":UIDevice.current.model,"scene_tags":tags.split(separator:",").map {$0.trimmingCharacters(in:.whitespaces)}]
            let data=try await api.request("/v1/projects/\(project)/sessions",method:"POST",json:body)
            let result=try JSONSerialization.jsonObject(with:data) as? [String:String]
            sessionID=result?["id"] ?? "";try await reload();message="Session saved. Capture a scene when ready."
        }
    }
    func capture() async {
        guard canCapture else {return}
        await perform {
            guard let detector,let health else {return}
            // Preflight is not a promise of upload success; retain one RAM buffer on failure.
            let capability=try await api.get("/v1/health",as:Health.self)
            guard capability.annotation_format=="yolo-segmentation-v1" else {throw CollectorError.message("Collector backend needs the polygon segmentation update before capturing")}
            let photo=try await camera.capture();camera.stop()
            message="Preparing upright image and draft boxes…"
            let (data,cg)=try canonicalJPEG(photo,maxDimension:health.max_image_dimension,maxBytes:health.max_image_bytes)
            let proposals=try await detector.infer(cg)
            let id=UUID().uuidString.lowercased()
            let encoded=try JSONEncoder().encode(proposals)
            let body:[String:Any]=["id":id,"project_id":project,"session_id":sessionID,"captured_at":ISO8601DateFormatter().string(from:Date()),"width":cg.width,"height":cg.height,"sha256":SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined(),"model_hash":collectorModelHash,"preprocessing_version":collectorPreprocessing,"proposals":try JSONSerialization.jsonObject(with:encoded)]
            pending=Pending(id:id,bytes:data,metadata:try JSONSerialization.data(withJSONObject:body,options:[.sortedKeys]))
            message="Uploading; the sample is saved only after the server confirms."
            try await uploadPending()
        }
        if pending==nil && review==nil {await camera.start()}
    }
    private func uploadPending() async throws {
        guard let capture=pending else {return}
        var lastError:Error?
        for attempt in 0..<3 {
            do {
                _=try await api.request("/v1/samples",method:"POST",bytes:capture.bytes,metadata:capture.metadata,id:capture.id)
                // Fetch the committed image through the no-cache data endpoint for review.
                try await fetchReview(capture.id);pending=nil
                try await reload();message="Saved to Neon. Review every visible target before approval.";return
            } catch {
                lastError=error
                if case CollectorError.http(let code,_)=error,(400..<500).contains(code),code != 408,code != 429 {
                    throw CollectorError.message("Server rejected this capture. "+error.localizedDescription+" Refresh or sign in again before retrying; release the buffer if the capture must be repeated.")
                }
                if attempt<2 {try await Task.sleep(nanoseconds:UInt64(attempt+1)*1_000_000_000)}
            }
        }
        connected=false
        throw CollectorError.message("Upload not acknowledged. Retry this RAM capture with the same ID. Closing the app can lose it. "+(lastError?.localizedDescription ?? ""))
    }
    func retry() async {await perform {try await uploadPending()}}
    func releasePending() async {
        pending=nil;message="Capture buffer released. Refresh the dataset to check whether an earlier request committed.";await refreshConnection();await camera.start()
    }
    private func fetchReview(_ id:String) async throws {
        let detail=try await api.get("/v1/samples/\(id)",as:SampleDetail.self)
        review=detail;annotations=detail.annotations.map(\.human);explicitNegative=detail.explicit_negative
        selected=nil;edited=false;undoHistory=[];addMode=false;camera.stop()
        guard detail.archived_at==nil else {image=nil;message="This sample's image was archived to Google Drive and can no longer be reviewed.";return}
        let bytes=try await api.request("/v1/samples/\(id)/image")
        guard let loaded=UIImage(data:bytes),let cg=loaded.cgImage,cg.width==detail.width,cg.height==detail.height else {throw CollectorError.message("Stored image dimensions disagree")}
        image=loaded
    }
    func open(_ id:String) async {await perform {try await fetchReview(id);if review?.archived_at==nil {message="Server image loaded. Pinch to zoom; select boxes to correct."}}}
    func beginEditing() async {
        await perform {
            try await writeReview(status:"pending_review");message="Approval invalidated on the server. Changes are drafts until saved."
        }
    }
    private func writeReview(status:String) async throws {
        guard let review else {return}
        let encoded=try JSONEncoder().encode(annotations.map(\.human))
        let body:[String:Any]=["expected_revision":review.current_revision,"status":status,"explicit_negative":status=="approved" && explicitNegative,"annotations":try JSONSerialization.jsonObject(with:encoded)]
        _=try await api.request("/v1/samples/\(review.id)/review",method:"PUT",json:body)
        try await fetchReview(review.id);try await reload()
    }
    func saveReview(approve:Bool) async {
        guard editable else {return}
        if addMode {message="Finish or cancel the polygon you are drawing before saving.";return}
        if approve,let reason=approvalBlockReason {message=reason;return}
        await perform {try await writeReview(status:approve ? "approved":"pending_review");message=approve ? "Review approved and saved to Neon.":"Draft annotations saved to Neon."}
    }
    func setBoxes(_ value:[Annotation]) {
        guard editable else {return}
        undoHistory.append(annotations);if undoHistory.count>20 {undoHistory.removeFirst()}
        annotations=value;explicitNegative=false;edited=true
    }
    func undoPolygonPoint() {guard editable,!polygonDraft.isEmpty else {return};polygonDraft.removeLast()}
    func cancelPolygon() {polygonDraft=[];addMode=false}
    func finishPolygon() {
        guard editable,polygonDraft.count>=3,let image else {return}
        let left=polygonDraft.map(\.x).min()!,right=polygonDraft.map(\.x).max()!
        let top=polygonDraft.map(\.y).min()!,bottom=polygonDraft.map(\.y).max()!
        guard right-left>1,bottom-top>1 else {message="Outline a visible area with at least three distinct points.";return}
        let box=Annotation(classID:0,x:left,y:top,width:right-left,height:bottom-top,points:polygonDraft)
        setBoxes(annotations+[box]);selected=box.id;cancelPolygon()
    }
    func convertSelectedToPolygon() {
        guard editable,let id=selected,let index=annotations.firstIndex(where:{$0.id==id}),annotations[index].points==nil else {return}
        var boxes=annotations;var box=boxes[index]
        box.points=[AnnotationPoint(x:box.x,y:box.y),AnnotationPoint(x:box.x+box.width,y:box.y),AnnotationPoint(x:box.x+box.width,y:box.y+box.height),AnnotationPoint(x:box.x,y:box.y+box.height)]
        boxes[index]=box;setBoxes(boxes)
    }
    func undo() {guard editable,let previous=undoHistory.popLast() else {return};annotations=previous;selected=nil;edited=true}
    func changeClass(_ classID:Int) {guard let id=selected,let index=annotations.firstIndex(where:{$0.id==id}) else {return};var copy=annotations;copy[index].classID=classID;setBoxes(copy)}
    func removeBox() {guard let id=selected else {return};setBoxes(annotations.filter {$0.id != id});selected=nil}
    func clearReview() {review=nil;image=nil;annotations=[];undoHistory=[];selected=nil;edited=false;addMode=false;addVertexMode=false;polygonDraft=[];explicitNegative=false}
    func closeReview() async {clearReview();await camera.start()}
    func discardSample() async {
        await perform {if let review {_=try await api.request("/v1/samples/\(review.id)",method:"DELETE");clearReview();try await reload();message="Sample discarded. Frozen exports retain their historical data."}}
        if review==nil {await camera.start()}
    }
    func freeze() async {
        await perform {_=try await api.request("/v1/projects/\(project)/versions",method:"POST");try await reload();message="Approved dataset frozen. Share its download link with the training computer."}
    }
    func link(_ version:String) async {
        await perform {
            let data=try await api.request("/v1/versions/\(version)/link",method:"POST")
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            shareURL=(object?["url"] as? String).flatMap(URL.init(string:))
            message="Link expires in 30 minutes. Download it on the training computer."
        }
    }
    func archiveNow() async {
        await perform {
            let data=try await api.request("/v1/projects/\(project)/archive",method:"POST")
            let result=try JSONDecoder().decode(ArchiveResult.self,from:data)
            if let link=result.drive_link {shareURL=URL(string:link)}
            let formatter=ByteCountFormatter();formatter.countStyle = .binary
            message="Archived \(result.samples) sample(s) (\(formatter.string(fromByteCount:Int64(result.bytes_freed))) freed) to Google Drive."+(result.warnings.first.map {" "+$0} ?? "")
            try await reload()
        }
    }
}
