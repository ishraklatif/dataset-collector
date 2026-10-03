import CoreGraphics
import Foundation

// Decodes a YOLO11n-seg TFLite model's per-detection mask coefficients + the
// shared prototype tensor into a simplified outline polygon, in the model's
// 320x320 letterboxed input space (callers reverse the letterbox separately,
// via Letterbox.canonicalPoints).
//
// Prototype tensor layout is NHWC (confirmed from the exported .tflite's own
// output_details, not assumed): protoSize*protoSize cells, each protoChannels
// floats, row-major by (y,x) - i.e. proto[(y*protoSize+x)*protoChannels+c].
enum CollectorSegmentation {
    static func polygon(coeffs:[Float],proto:[Float],protoSize:Int=80,protoChannels:Int=32,
                         upscaleSize:Int=320,threshold:Float=0.5,maxPoints:Int=64)->[CGPoint]? {
        guard coeffs.count==protoChannels,proto.count==protoSize*protoSize*protoChannels else {return nil}
        var small=[Bool](repeating:false,count:protoSize*protoSize)
        for cell in 0..<(protoSize*protoSize) {
            var sum:Float=0
            let base=cell*protoChannels
            for c in 0..<protoChannels {sum+=coeffs[c]*proto[base+c]}
            small[cell]=(1/(1+expf(-sum)))>threshold
        }
        guard upscaleSize%protoSize==0 else {return nil}
        let scale=upscaleSize/protoSize
        var large=[Bool](repeating:false,count:upscaleSize*upscaleSize)
        for y in 0..<protoSize {
            for x in 0..<protoSize where small[y*protoSize+x] {
                for dy in 0..<scale {
                    let row=(y*scale+dy)*upscaleSize
                    for dx in 0..<scale {large[row+x*scale+dx]=true}
                }
            }
        }
        guard let contour=traceContour(large,width:upscaleSize,height:upscaleSize) else {return nil}
        return simplifyToLimit(contour,maxPoints:maxPoints)
    }

    // Moore-neighbor boundary tracing (8-connected). Returns the closed outline's
    // pixel-corner points in walk order, or nil if the mask has no foreground.
    static func traceContour(_ mask:[Bool],width:Int,height:Int)->[CGPoint]? {
        func at(_ x:Int,_ y:Int)->Bool {
            guard x>=0,x<width,y>=0,y<height else {return false}
            return mask[y*width+x]
        }
        guard let start=(0..<(width*height)).first(where:{mask[$0]}) else {return nil}
        let startX=start%width,startY=start/width
        // Clockwise neighbor offsets starting "north" so the first search direction
        // (from a pixel entered from the west, i.e. backtrack=west) is well-defined.
        let neighbors=[(0,-1),(1,-1),(1,0),(1,1),(0,1),(-1,1),(-1,0),(-1,-1)]
        var points:[CGPoint]=[CGPoint(x:startX,y:startY)]
        var curX=startX,curY=startY
        var backtrackDir=6 // west, since start is the first foreground pixel in row-major scan
        var iterations=0
        let maxIterations=width*height*8
        repeat {
            var found=false
            for step in 0..<8 {
                let dir=(backtrackDir+1+step)%8
                let (dx,dy)=neighbors[dir]
                if at(curX+dx,curY+dy) {
                    curX+=dx;curY+=dy
                    points.append(CGPoint(x:curX,y:curY))
                    backtrackDir=(dir+5)%8 // neighbor just before this one, clockwise
                    found=true
                    break
                }
            }
            if !found {break} // isolated single pixel
            iterations+=1
        } while (curX != startX || curY != startY) && iterations<maxIterations
        return points.count>=3 ? points:nil
    }

    // Douglas-Peucker simplification, escalating tolerance until the point count
    // fits maxPoints (domain.py enforces 3-256 points server-side; a bundled model
    // proposal should stay well under that for a usefully editable polygon).
    static func simplifyToLimit(_ points:[CGPoint],maxPoints:Int)->[CGPoint] {
        var tolerance:CGFloat=1
        var result=points
        for _ in 0..<20 {
            result=douglasPeucker(points,tolerance:tolerance)
            if result.count<=maxPoints {break}
            tolerance*=1.6
        }
        if result.count>maxPoints {
            // Still too many (degenerate/noisy mask): evenly resample as a last resort.
            let step=Double(result.count)/Double(maxPoints)
            result=(0..<maxPoints).map {result[Int(Double($0)*step)]}
        }
        return result
    }

    static func douglasPeucker(_ points:[CGPoint],tolerance:CGFloat)->[CGPoint] {
        guard points.count>2 else {return points}
        func perpendicularDistance(_ p:CGPoint,_ a:CGPoint,_ b:CGPoint)->CGFloat {
            let dx=b.x-a.x,dy=b.y-a.y
            let lengthSq=dx*dx+dy*dy
            if lengthSq==0 {return hypot(p.x-a.x,p.y-a.y)}
            let t=((p.x-a.x)*dx+(p.y-a.y)*dy)/lengthSq
            let projection=CGPoint(x:a.x+t*dx,y:a.y+t*dy)
            return hypot(p.x-projection.x,p.y-projection.y)
        }
        func recurse(_ pts:ArraySlice<CGPoint>)->[CGPoint] {
            guard pts.count>2,let first=pts.first,let last=pts.last else {return Array(pts)}
            var maxDistance:CGFloat=0,maxIndex=pts.startIndex
            for i in pts.indices where i != pts.startIndex && i != pts.indices.last {
                let d=perpendicularDistance(pts[i],first,last)
                if d>maxDistance {maxDistance=d;maxIndex=i}
            }
            guard maxDistance>tolerance else {return [first,last]}
            let left=recurse(pts[pts.startIndex...maxIndex])
            let right=recurse(pts[maxIndex...pts.index(before:pts.endIndex)])
            return left.dropLast()+right
        }
        // Closed polygon: simplify as an open path from the first point around back to it,
        // then drop the duplicated closing point.
        var closed=points;closed.append(points[0])
        let result=recurse(closed[...])
        return Array(result.dropLast())
    }
}
