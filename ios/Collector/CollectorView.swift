import SwiftUI

struct CollectorView:View {
    @StateObject private var store=CollectorStore()
    @ObservedObject private var activity=AppActivity.shared
    @State private var sheet:Sheet?
    @State private var discard=false
    @State private var close=false
    @State private var release=false
    enum Sheet:String,Identifiable {case connection,session,dataset;var id:String {rawValue}}
    var body:some View {
        NavigationStack {
            VStack(spacing:12) {
                HStack {
                    Label(store.connected ? "Connected":"Collection paused",systemImage:store.connected ? "checkmark.icloud":"icloud.slash")
                        .font(.caption.weight(.semibold)).foregroundStyle(store.connected ? .green:.orange)
                    Spacer()
                    Button("Connection") {sheet = .connection}.font(.caption)
                }
                HStack {
                    Button {sheet = .session} label: {Label(store.sessions.first(where:{$0.id==store.sessionID})?.name ?? "Choose session",systemImage:"rectangle.stack")}.disabled(store.review != nil)
                    Spacer()
                    Button {sheet = .dataset} label: {Label("Dataset",systemImage:"square.stack.3d.up")}.disabled(store.edited)
                }.font(.subheadline).disabled(store.busy || store.hasPending)
                ZStack {
                    // Preview layer is mounted once and stays mounted for the screen's lifetime;
                    // only its visibility toggles. Tearing it down and recreating it on every
                    // capture/review cycle reattaches the layer to a session that is simultaneously
                    // stopping/starting, which can leave it attached but never fed frames.
                    LivePreview(camera:store.camera).opacity(store.image==nil && store.review==nil ? 1:0)
                    if let image=store.image {
                        BoxEditor(image:image,annotations:store.annotations,selected:store.selected,editable:store.editable,adding:store.addMode,addingVertex:store.addVertexMode,draftPoints:store.polygonDraft,onSelect:{store.selected=$0},onEdit:store.setBoxes,onDraftChange:{store.polygonDraft=$0})
                    } else if store.review?.archived_at != nil {
                        Text("Image archived to Google Drive. Open the Drive copy to view it.").foregroundStyle(.white).padding().background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius:12))
                    } else if !store.camera.available {
                        Text(store.camera.problem ?? "Preparing camera…").padding().background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius:12))
                    }
                    if !activity.active {Color.black}
                }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.black).clipShape(RoundedRectangle(cornerRadius:18))
                if store.review != nil {reviewControls} else {captureControls}
                Text(store.message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("collectorStatus")
                if let warning=store.storageWarning {
                    Label(warning,systemImage:"exclamationmark.triangle.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("storageWarning")
                }
                if let p=store.page {
                    HStack {Text("\(p.counts.reduce(0){$0+$1.count}) saved");Spacer();Text("\(p.counts.first(where:{$0.status=="pending_review"})?.count ?? 0) pending review")}.font(.caption).foregroundStyle(.secondary)
                }
            }.padding().navigationTitle("AR Dataset Collector").navigationBarTitleDisplayMode(.inline)
                .overlay {if store.busy {ProgressView().padding(20).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius:14))}}
                .sheet(item:$sheet) {item in sheetView(item)}
                .alert("Discard this sample?",isPresented:$discard) {Button("Discard",role:.destructive) {Task {await store.discardSample()}};Button("Cancel",role:.cancel) {}} message: {Text("It will be removed from collection. Existing frozen dataset versions retain it.")}
                .alert("Release the unacknowledged capture?",isPresented:$release) {Button("Release",role:.destructive) {Task {await store.releasePending()}};Button("Cancel",role:.cancel) {}} message: {Text("The RAM buffer cannot be recovered after release. An earlier upload may have committed; the dataset will be refreshed.")}
                .alert("Leave unsaved review edits?",isPresented:$close) {Button("Leave",role:.destructive) {Task {await store.closeReview()}};Button("Cancel",role:.cancel) {}} message: {Text("Only server-confirmed revisions survive closing the app.")}
                .alert("Database storage is nearly full",isPresented:$store.archivePrompt) {Button("Export & Free Space") {Task {await store.archiveNow()}};Button("Not now",role:.cancel) {}} message: {Text("Archive newly approved samples to Google Drive to free up space. This permanently removes their images from this database; the Drive copy becomes the only copy.")}
                .task {await store.initialize()}
                .task {while !Task.isCancelled {try? await Task.sleep(nanoseconds:15_000_000_000);if activity.active {await store.refreshConnection()}}}
                .onChange(of:activity.active) {isActive in
                    if !isActive {store.camera.stop()} else {Task {await store.refreshConnection();if store.review==nil && !store.hasPending {await store.camera.start()}}}
                }
        }.tint(Color(red:0.05,green:0.45,blue:0.43))
    }
    private var captureControls:some View {
        VStack(spacing:8) {
            if store.hasPending {
                HStack {Button("Retry upload") {Task {await store.retry()}}.buttonStyle(.borderedProminent);Button("Release buffer",role:.destructive) {release=true}}.disabled(store.busy)
                Text("One capture is held in RAM. Keep the app open until the server confirms.").font(.caption)
            } else {
                Button {Task {await store.capture()}} label: {Label("Capture photograph",systemImage:"camera.fill").frame(maxWidth:.infinity).padding(.vertical,8)}
                    .buttonStyle(.borderedProminent).disabled(!store.canCapture).accessibilityIdentifier("captureButton")
                Text("Draft predictions require human review. Photos upload to Neon; they are not saved on this iPhone.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var reviewControls:some View {
        VStack(spacing:8) {
            HStack {Text(store.review?.status=="approved" ? "Approved review":"Pending review").font(.subheadline.weight(.semibold));Spacer();if store.edited {Text("Unsaved edits").font(.caption).foregroundStyle(.orange)}}
            if store.review?.archived_at != nil {
                Text("Archived to Google Drive. This sample's annotations are permanent and can no longer be edited.").font(.caption).foregroundStyle(.secondary)
            } else if store.review?.status=="approved" {
                Button("Edit annotations · mark pending") {Task {await store.beginEditing()}}.buttonStyle(.bordered).disabled(store.busy)
            } else {
                HStack {
                    Button(store.addMode ? "Cancel polygon":"Add polygon",systemImage:store.addMode ? "xmark":"plus") {
                        store.addVertexMode=false
                        if store.addMode {store.cancelPolygon()} else {store.polygonDraft=[];store.addMode=true}
                    }
                    Button("Undo",systemImage:"arrow.uturn.backward") {store.undo()}
                    Button("Delete",systemImage:"trash",role:.destructive) {store.removeBox()}.disabled(store.selected==nil)
                }.font(.caption).disabled(!store.editable)
                if store.addMode {
                    HStack {
                        Button("Undo point") {store.undoPolygonPoint()}.disabled(store.polygonDraft.isEmpty)
                        Spacer()
                        Text("\(store.polygonDraft.count) points").font(.caption.monospacedDigit())
                        Spacer()
                        Button("Finish polygon") {store.finishPolygon()}.disabled(store.polygonDraft.count<3)
                    }.font(.caption)
                    Text("Tap around the object outline, then finish with at least 3 points.").font(.caption).foregroundStyle(.secondary)
                }
                if let b=store.annotations.first(where:{$0.id==store.selected}) {
                    HStack {
                        if b.points==nil {
                            Button("Convert box to polygon") {store.convertSelectedToPolygon()}
                        } else {
                            Button(store.addVertexMode ? "Done adding vertices":"Add vertex") {store.addVertexMode.toggle();if store.addVertexMode {store.cancelPolygon()}}
                        }
                    }.font(.caption).disabled(!store.editable || store.addMode)
                    Picker("Class",selection:Binding(get:{b.classID},set:store.changeClass)) {
                        ForEach(collectorClasses.indices,id:\.self) {Text(collectorClasses[$0]).tag($0)}
                    }.pickerStyle(.menu).disabled(!store.editable)
                }
                    if store.annotations.isEmpty {Toggle("I reviewed this image: no target objects are present",isOn:$store.explicitNegative).font(.caption).disabled(!store.editable).onChange(of:store.explicitNegative) {_ in if store.editable {store.edited=true}}}
                Text("Add a polygon by tapping its outline. Convert prediction boxes and add vertices along their edges. Drag vertices to refine outlines; drag inside a shape to move it.").font(.caption).foregroundStyle(.secondary)
                if let reason=store.approvalBlockReason {
                    Text(reason).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                HStack {
                    Button("Save draft") {Task {await store.saveReview(approve:false)}}.buttonStyle(.bordered).disabled(!store.editable || store.addMode)
                    Button("Approve") {Task {await store.saveReview(approve:true)}}.buttonStyle(.borderedProminent).disabled(!store.editable || !store.readyToApprove)
                }
            }
            HStack {
                Button("Discard sample",role:.destructive) {discard=true}
                Spacer()
                Button("Back to capture") {if store.edited {close=true} else {Task {await store.closeReview()}}}
            }.font(.caption).disabled(store.busy)
        }
    }
    @ViewBuilder private func sheetView(_ item:Sheet)->some View {
        NavigationStack {
            Group {
                switch item {
                case .connection:connectionSheet
                case .session:sessionSheet
                case .dataset:datasetSheet
                }
            }.navigationTitle(item == .connection ? "Connection":item == .session ? "Capture session":"Dataset")
                .toolbar {ToolbarItem(placement:.confirmationAction) {Button("Done") {sheet=nil}}}
        }
    }
    private var connectionSheet:some View {
        Form {
            Section("Collector backend") {
                TextField("https://collector.example.com",text:$store.endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Operator username",text:$store.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password",text:$store.password).textContentType(.password)
                Button("Sign in") {Task {await store.signIn()}}.disabled(store.busy || store.hasPending || store.review != nil)
                Button("Check connection") {Task {await store.refreshConnection()}}.disabled(store.busy)
                if store.api.token != nil {Button("Sign out",role:.destructive) {Task {await store.signOut()}}.disabled(store.busy || store.hasPending || store.edited)}
            }
            Section {Text(store.message);Text("Revocable operator sessions are stored in Keychain. Database credentials stay on the backend.")}
        }
    }
    private var sessionSheet:some View {
        Form {
            if let h=store.health,h.projects.count>1 {Picker("Project",selection:$store.project) {ForEach(h.projects) {Text($0.name).tag($0.id)}}.onChange(of:store.project) {_ in store.sessionID="";Task {await store.refreshConnection()}}}
            Section("Existing sessions") {
                ForEach(store.sessions) {s in Button {store.sessionID=s.id;sheet=nil} label: {VStack(alignment:.leading) {Text(s.name);Text("\(s.specimen_name) · \(s.designation)").font(.caption).foregroundStyle(.secondary)}}}
            }
            Section("New session") {
                TextField("Session name",text:$store.sessionName)
                TextField("Specimen identity (reuse for the same specimen)",text:$store.specimenName)
                Picker("Specimen",selection:$store.designation) {Text("Proxy").tag("proxy");Text("Real").tag("real")}.pickerStyle(.segmented)
                TextField("Scene tags, separated by commas",text:$store.tags)
                Button("Create session") {Task {await store.createSession();if !store.sessionID.isEmpty {sheet=nil}}}.disabled(!store.connected || store.busy || store.sessionName.isEmpty || store.specimenName.isEmpty)
            }
            Text("Keep related scene captures and specimens grouped when preparing training splits. Prioritize rotated, handheld, and distant tubes and bags.").font(.footnote)
            Text(store.message).font(.footnote)
        }
    }
    private var datasetSheet:some View {
        List {
            Section("Server-confirmed counts") {
                if let p=store.page {
                    ForEach(p.counts,id:\.status) {Text("\($0.status): \($0.count) images")}
                    ForEach(collectorClasses.indices,id:\.self) {i in
                        let count=p.classes.first(where:{$0.class_id==i})
                        Text("\(collectorClasses[i]): \(count?.images ?? 0) images · \(count?.instances ?? 0) objects")
                    }
                }
                Button("Refresh") {Task {await store.refreshConnection()}}
            }
            Section("Samples") {
                ForEach(store.samples) {s in Button {Task {await store.open(s.id);if store.review != nil {sheet=nil}}} label: {VStack(alignment:.leading) {Text((s.status == "approved" ? "Approved":"Pending review")+(s.archived_at != nil ? " · Archived to Drive":""));Text(s.labels).font(.caption);Text(String(s.id.prefix(8))+" · session "+String(s.session_id.prefix(8))).font(.caption).foregroundStyle(.secondary)}}}
                if store.page?.next_offset != nil {Button("Load more") {Task {await store.loadMore()}}}
            }
            Section("Versioned exports") {
                Button("Freeze approved collection") {Task {await store.freeze()}}.disabled(!store.connected || store.busy)
                Button("Export & Free Space (Google Drive)") {Task {await store.archiveNow()}}.disabled(!store.connected || store.busy)
                ForEach(store.versions) {v in VStack(alignment:.leading,spacing:6) {
                    Text("\(String(v.id.prefix(8))) · \(v.samples) images · \(v.status)")
                    if let link=v.drive_link,let url=URL(string:link) {Link("Open in Google Drive",destination:url).font(.caption)}
                    else {Button("Create training-computer download link") {Task {await store.link(v.id)}}.font(.caption)}
                }}
                if let url=store.shareURL {ShareLink(item:url) {Label("Share expiring download link",systemImage:"square.and.arrow.up")}}
                Text("Only a link is shared. Download the ZIP on the training computer. The bundle is unsplit; prepare grouped splits before training. Archiving to Google Drive permanently removes those images from this database.").font(.footnote).foregroundStyle(.secondary)
            }
            Text(store.message).font(.footnote)
        }
    }
}

struct LivePreview:View {
    @ObservedObject var camera:CollectorCamera
    var body:some View {
        GeometryReader {g in
            ZStack(alignment:.topLeading) {
                CameraPreview(camera:camera)
                if camera.available {
                    let scale=min(g.size.width/camera.liveSize.width,g.size.height/camera.liveSize.height)
                    let offset=CGPoint(x:(g.size.width-camera.liveSize.width*scale)/2,y:(g.size.height-camera.liveSize.height*scale)/2)
                    ForEach(camera.liveBoxes) {b in
                        Rectangle().stroke(.mint,lineWidth:2).frame(width:b.width*scale,height:b.height*scale).position(x:offset.x+(b.x+b.width/2)*scale,y:offset.y+(b.y+b.height/2)*scale)
                        Text(b.label+" "+String(format:"%.0f%%",(b.confidence ?? 0)*100)).font(.system(size:10,weight:.semibold)).padding(3).background(.mint).foregroundStyle(.black).offset(x:offset.x+b.x*scale,y:max(0,offset.y+b.y*scale-20))
                    }
                }
            }
        }
    }
}
