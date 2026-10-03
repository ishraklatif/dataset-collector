import SwiftUI

struct BoxEditor:UIViewRepresentable {
    let image:UIImage
    let annotations:[Annotation]
    let selected:UUID?
    let editable:Bool
    let adding:Bool
    let addingVertex:Bool
    let draftPoints:[AnnotationPoint]
    let onSelect:(UUID?)->Void
    let onEdit:([Annotation])->Void
    let onDraftChange:([AnnotationPoint])->Void
    func makeUIView(context:Context)->EditorView {let view=EditorView();view.apply(self);return view}
    func updateUIView(_ view:EditorView,context:Context) {view.apply(self)}
}

final class EditorView:UIView,UIScrollViewDelegate,UIGestureRecognizerDelegate {
    private enum ResizeHandle:CaseIterable {
        case topLeft,top,topRight,right,bottomRight,bottom,bottomLeft,left
        var movesLeft:Bool {self == .topLeft || self == .left || self == .bottomLeft}
        var movesRight:Bool {self == .topRight || self == .right || self == .bottomRight}
        var movesTop:Bool {self == .topLeft || self == .top || self == .topRight}
        var movesBottom:Bool {self == .bottomLeft || self == .bottom || self == .bottomRight}
    }
    private let scroll=UIScrollView()
    private let content=UIImageView()
    private let overlay=CALayer()
    private var model:BoxEditor?
    private var original:Annotation?
    private var resizeHandle:ResizeHandle?
    private var vertexIndex:Int?
    private var draggingBoxes:[Annotation]?
    private var fitDone=false
    override init(frame:CGRect) {
        super.init(frame:frame)
        scroll.delegate=self;scroll.maximumZoomScale=8;scroll.backgroundColor = .black
        content.isUserInteractionEnabled=true;content.contentMode = .scaleToFill
        addSubview(scroll);scroll.addSubview(content);content.layer.addSublayer(overlay)
        let tap=UITapGestureRecognizer(target:self,action:#selector(tapped(_:)));content.addGestureRecognizer(tap)
        let pan=UIPanGestureRecognizer(target:self,action:#selector(dragged(_:)));pan.delegate=self;pan.maximumNumberOfTouches=1;content.addGestureRecognizer(pan)
        scroll.panGestureRecognizer.minimumNumberOfTouches=2
        accessibilityLabel="Image segmentation editor. Tap points around an outline, drag vertices to refine it, drag inside a shape to move it, pinch to zoom, and use two fingers to pan."
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    func apply(_ model:BoxEditor) {
        if content.image !== model.image {
            content.image=model.image;fitDone=false;scroll.zoomScale=1
            let size=CGSize(width:model.image.cgImage?.width ?? 1,height:model.image.cgImage?.height ?? 1)
            content.frame=CGRect(origin:.zero,size:size);scroll.contentSize=size
        }
        self.model=model;scroll.panGestureRecognizer.minimumNumberOfTouches=model.editable ? 2:1
        setNeedsLayout();render(draggingBoxes ?? model.annotations)
    }
    override func layoutSubviews() {
        super.layoutSubviews();scroll.frame=bounds
        if !fitDone,bounds.width>0,bounds.height>0,content.bounds.width>0 {
            let fit=min(bounds.width/content.bounds.width,bounds.height/content.bounds.height)
            scroll.minimumZoomScale=fit;scroll.maximumZoomScale=max(8*fit,1);scroll.zoomScale=fit;fitDone=true
        }
        centerContent()
    }
    private func centerContent() {
        let x=max(0,(scroll.bounds.width-content.frame.width)/2),y=max(0,(scroll.bounds.height-content.frame.height)/2)
        scroll.contentInset=UIEdgeInsets(top:y,left:x,bottom:y,right:x)
    }
    func viewForZooming(in scrollView:UIScrollView)->UIView? {content}
    func scrollViewDidZoom(_ scrollView:UIScrollView) {centerContent();if let model {render(draggingBoxes ?? model.annotations)}}
    private func path(for box:Annotation)->UIBezierPath {
        guard let points=box.points,points.count>=3 else {return UIBezierPath(rect:box.rect)}
        let path=UIBezierPath();path.move(to:points[0].cgPoint)
        for point in points.dropFirst() {path.addLine(to:point.cgPoint)}
        path.close();return path
    }
    private func render(_ boxes:[Annotation]) {
        overlay.sublayers?.forEach {$0.removeFromSuperlayer()};overlay.frame=content.bounds
        let scale=max(scroll.zoomScale,0.001)
        for box in boxes {
            let selected=box.id==model?.selected
            let color=selected ? UIColor.systemYellow:UIColor.systemTeal
            let shape=CAShapeLayer();shape.path=path(for:box).cgPath;shape.fillColor=UIColor.clear.cgColor
            shape.strokeColor=color.cgColor;shape.lineWidth=(selected ? 3:2)/scale;overlay.addSublayer(shape)
            let label=CATextLayer();label.string=box.label;label.fontSize=11/scale;label.foregroundColor=UIColor.black.cgColor
            label.backgroundColor=color.cgColor;label.contentsScale=UIScreen.main.scale
            label.frame=CGRect(x:box.x,y:max(0,box.y-16/scale),width:min(box.width,190/scale),height:16/scale);overlay.addSublayer(label)
            if selected,model?.editable==true {
                if let points=box.points {
                    for point in points {addHandle(at:point.cgPoint,color:color,scale:scale,diamond:true)}
                } else {
                    for (_,point) in handlePoints(for:box.rect) {addHandle(at:point,color:color,scale:scale,diamond:false)}
                }
            }
        }
        if let model,model.adding,!model.draftPoints.isEmpty {
            let points=model.draftPoints.map(\.cgPoint),draft=UIBezierPath();draft.move(to:points[0])
            for point in points.dropFirst() {draft.addLine(to:point)}
            let line=CAShapeLayer();line.path=draft.cgPath;line.strokeColor=UIColor.systemYellow.cgColor;line.fillColor=UIColor.clear.cgColor;line.lineWidth=3/scale
            if points.count>=3 {line.lineDashPattern=[NSNumber(value:Double(6/scale)),NSNumber(value:Double(4/scale))]}
            overlay.addSublayer(line)
            for point in points {addHandle(at:point,color:.systemYellow,scale:scale,diamond:false)}
        }
    }
    private func addHandle(at point:CGPoint,color:UIColor,scale:CGFloat,diamond:Bool) {
        let size=22/scale,rect=CGRect(x:point.x-size/2,y:point.y-size/2,width:size,height:size)
        let shape=CAShapeLayer()
        if diamond {let p=UIBezierPath();p.move(to:CGPoint(x:point.x,y:rect.minY));p.addLine(to:CGPoint(x:rect.maxX,y:point.y));p.addLine(to:CGPoint(x:point.x,y:rect.maxY));p.addLine(to:CGPoint(x:rect.minX,y:point.y));p.close();shape.path=p.cgPath}
        else {shape.path=UIBezierPath(roundedRect:rect,cornerRadius:4/scale).cgPath}
        shape.fillColor=color.cgColor;shape.strokeColor=UIColor.black.cgColor;shape.lineWidth=2/scale;overlay.addSublayer(shape)
    }
    private func handlePoints(for rect:CGRect)->[(ResizeHandle,CGPoint)] {
        [(.topLeft,CGPoint(x:rect.minX,y:rect.minY)),(.top,CGPoint(x:rect.midX,y:rect.minY)),(.topRight,CGPoint(x:rect.maxX,y:rect.minY)),(.right,CGPoint(x:rect.maxX,y:rect.midY)),(.bottomRight,CGPoint(x:rect.maxX,y:rect.maxY)),(.bottom,CGPoint(x:rect.midX,y:rect.maxY)),(.bottomLeft,CGPoint(x:rect.minX,y:rect.maxY)),(.left,CGPoint(x:rect.minX,y:rect.midY))]
    }
    private func hitHandle(at point:CGPoint,in rect:CGRect)->ResizeHandle? {
        let tolerance=38/max(scroll.zoomScale,0.001)
        return handlePoints(for:rect).first {hypot(point.x-$0.1.x,point.y-$0.1.y)<=tolerance}?.0
    }
    private func hitVertex(at point:CGPoint,in box:Annotation)->Int? {
        guard let points=box.points else {return nil}
        let tolerance=38/max(scroll.zoomScale,0.001)
        return points.indices.first {hypot(point.x-points[$0].x,point.y-points[$0].y)<=tolerance}
    }
    private func contains(_ point:CGPoint,in box:Annotation)->Bool {
        guard let points=box.points,points.count>=3 else {return box.rect.contains(point)}
        let path=UIBezierPath();path.move(to:points[0].cgPoint)
        for item in points.dropFirst() {path.addLine(to:item.cgPoint)}
        path.close();return path.contains(point)
    }
    private func updateBounds(_ box:inout Annotation) {
        guard let points=box.points,!points.isEmpty else {return}
        box.x=points.map(\.x).min()!;box.y=points.map(\.y).min()!
        box.width=points.map(\.x).max()!-box.x;box.height=points.map(\.y).max()!-box.y
    }
    private func insertedVertex(at point:CGPoint,in box:Annotation)->Annotation? {
        guard var points=box.points,points.count>=3 else {return nil}
        var nearest:(index:Int,point:CGPoint,distance:CGFloat)?
        for index in points.indices {
            let a=points[index].cgPoint,b=points[(index+1)%points.count].cgPoint
            let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
            let t=length==0 ? 0:max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/length))
            let candidate=CGPoint(x:a.x+t*dx,y:a.y+t*dy),distance=hypot(point.x-candidate.x,point.y-candidate.y)
            if nearest==nil || distance<nearest!.distance {nearest=(index,candidate,distance)}
        }
        guard let nearest,nearest.distance<=48/max(scroll.zoomScale,0.001) else {return nil}
        points.insert(AnnotationPoint(nearest.point),at:nearest.index+1)
        var edited=box;edited.points=points;updateBounds(&edited);return edited
    }
    @objc private func tapped(_ recognizer:UITapGestureRecognizer) {
        guard let model else {return};let point=recognizer.location(in:content)
        if model.adding,model.editable,model.draftPoints.count<256,content.bounds.contains(point) {
            model.onDraftChange(model.draftPoints+[AnnotationPoint(point)]);return
        }
        if model.addingVertex,model.editable,let id=model.selected,let index=model.annotations.firstIndex(where:{$0.id==id}),var edited=insertedVertex(at:point,in:model.annotations[index]) {
            var boxes=model.annotations;boxes[index]=edited;model.onEdit(boxes);return
        }
        model.onSelect(model.annotations.filter {contains(point,in:$0)}.min(by:{$0.width*$0.height<$1.width*$1.height})?.id)
    }
    override func gestureRecognizerShouldBegin(_ recognizer:UIGestureRecognizer)->Bool {
        guard model?.editable==true,let id=model?.selected,let box=model?.annotations.first(where:{$0.id==id}) else {return false}
        let point=recognizer.location(in:content)
        if hitVertex(at:point,in:box) != nil {return true}
        if box.points==nil,hitHandle(at:point,in:box.rect) != nil {return true}
        return contains(point,in:box) || box.rect.insetBy(dx:-30/max(scroll.zoomScale,0.001),dy:-30/max(scroll.zoomScale,0.001)).contains(point)
    }
    @objc private func dragged(_ recognizer:UIPanGestureRecognizer) {
        guard let model,model.editable,let id=model.selected,let index=model.annotations.firstIndex(where:{$0.id==id}) else {return}
        if recognizer.state == .began {
            original=model.annotations[index]
            let point=recognizer.location(in:content),box=model.annotations[index]
            vertexIndex=hitVertex(at:point,in:box)
            resizeHandle=box.points==nil ? hitHandle(at:point,in:box.rect):nil
        }
        guard var box=original else {return}
        let delta=recognizer.translation(in:content)
        if var points=box.points {
            if let index=vertexIndex {
                let source=points[index]
                points[index]=AnnotationPoint(x:max(0,min(source.x+Double(delta.x),Double(content.bounds.width))),y:max(0,min(source.y+Double(delta.y),Double(content.bounds.height))))
            } else {
                let minX=points.map(\.x).min()!,maxX=points.map(\.x).max()!,minY=points.map(\.y).min()!,maxY=points.map(\.y).max()!
                let dx=max(-minX,min(Double(delta.x),Double(content.bounds.width)-maxX)),dy=max(-minY,min(Double(delta.y),Double(content.bounds.height)-maxY))
                points=points.map {AnnotationPoint(x:$0.x+dx,y:$0.y+dy)}
            }
            box.points=points;updateBounds(&box)
        } else if let handle=resizeHandle {
            let rect=box.rect
            var left=rect.minX,right=rect.maxX,top=rect.minY,bottom=rect.maxY
            if handle.movesLeft {left=max(0,min(rect.minX+delta.x,rect.maxX-1))}
            if handle.movesRight {right=min(content.bounds.width,max(rect.maxX+delta.x,rect.minX+1))}
            if handle.movesTop {top=max(0,min(rect.minY+delta.y,rect.maxY-1))}
            if handle.movesBottom {bottom=min(content.bounds.height,max(rect.maxY+delta.y,rect.minY+1))}
            box.x=left;box.y=top;box.width=right-left;box.height=bottom-top
        } else {
            box.x=max(0,min(box.x+delta.x,content.bounds.width-box.width));box.y=max(0,min(box.y+delta.y,content.bounds.height-box.height))
        }
        var boxes=model.annotations;boxes[index]=box;draggingBoxes=boxes;render(boxes)
        if recognizer.state == .ended {model.onEdit(boxes);draggingBoxes=nil;original=nil;resizeHandle=nil;vertexIndex=nil}
        if recognizer.state == .cancelled || recognizer.state == .failed {draggingBoxes=nil;original=nil;resizeHandle=nil;vertexIndex=nil;render(model.annotations)}
    }
}
