import CoreGraphics
import Foundation

/// Original paths in a 32pt cell (24pt arrow / 28pt pointing-hand width).
/// All geometry is authored here; system cursors are used only through recorded sidecars.
func drawAuthoredCursor(_ style: VectorCursorStyle,preset: VectorCursorSet,variant: VectorCursorVariant,
                        pressed: Bool,in c: CGContext,space: CGColorSpace) {
    let geometry = preset.geometry
    let index = CGFloat(VectorCursorSet.Geometry.allCases.firstIndex(of: geometry)!)
    let alternate = variant == .alternate
    let angular = [VectorCursorSet.Geometry.cutPaper,.kite,.chevron,.facet,.technical].contains(geometry)
    let width = min(2.2,CGFloat(preset.weight))
    func color(_ v: SIMD4<Float>) -> CGColor { CGColor(colorSpace: space,components: [CGFloat(v.x),CGFloat(v.y),CGFloat(v.z),CGFloat(v.w)])! }
    c.setLineJoin(angular ? .miter : .round); c.setMiterLimit(2)
    c.setLineCap(angular ? .square : .round)
    func polygon(_ points: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath(); return path
    }
    func points(_ xy: [(Double,Double)]) -> [CGPoint] { xy.map { CGPoint(x: $0.0,y: $0.1) } }
    func paint(_ path: CGPath,hand: Bool = false,evenOdd: Bool = false) {
        c.addPath(path); c.setFillColor(color(hand ? preset.handFill : preset.arrowFill))
        c.setStrokeColor(color(hand ? preset.handOutline : preset.outline)); c.setLineWidth(width*0.7)
        c.drawPath(using: evenOdd ? .eoFillStroke : .fillStroke)
    }
    func stroke(_ path: CGPath,lineWidth: CGFloat = 1.5) {
        c.addPath(path); c.setStrokeColor(color(preset.outline)); c.setLineWidth(lineWidth+1.3); c.strokePath()
        c.addPath(path); c.setStrokeColor(color(preset.arrowFill)); c.setLineWidth(lineWidth); c.strokePath()
    }
    let path = CGMutablePath()
    switch style {
    case .arrow:
        if alternate {
            // A shaftless pen/triangle variant keeps the same action point.
            let reach = 18+Double(index)*0.45
            path.addLines(between: points([(3,3),(5,reach+7),(10,reach-1),(20,reach-3)])); path.closeSubpath()
            if geometry == .cutPaper || geometry == .technical {
                path.addPath(polygon(points([(6,10),(7,20),(12,16)])))
            }
        } else {
            switch geometry {
            case .classic:
                path.addLines(between: points([(3,3),(3,24),(8,19),(12,29),(16,27),(12,17),(21,17)])); path.closeSubpath()
            case .cutPaper:
                path.addLines(between: points([(3,3),(3,26),(8,20),(12,29),(15,27),(10,17),(21,17)])); path.closeSubpath()
                path.addPath(polygon(points([(6,10),(6,18),(13,15)])))
            case .rounded:
                path.move(to: CGPoint(x: 3,y: 3)); path.addLine(to: CGPoint(x: 3,y: 23))
                path.addQuadCurve(to: CGPoint(x: 7,y: 23),control: CGPoint(x: 3,y: 27))
                path.addLine(to: CGPoint(x: 9,y: 20)); path.addLine(to: CGPoint(x: 13,y: 28))
                path.addCurve(to: CGPoint(x: 17,y: 26),control1: CGPoint(x: 15,y: 30),control2: CGPoint(x: 19,y: 29))
                path.addLine(to: CGPoint(x: 13,y: 18)); path.addLine(to: CGPoint(x: 19,y: 18))
                path.addQuadCurve(to: CGPoint(x: 20,y: 15),control: CGPoint(x: 23,y: 18)); path.closeSubpath()
            case .pill:
                path.move(to: CGPoint(x: 3,y: 3)); path.addLine(to: CGPoint(x: 4,y: 22))
                path.addQuadCurve(to: CGPoint(x: 8,y: 21),control: CGPoint(x: 4,y: 26))
                path.addLine(to: CGPoint(x: 12,y: 28)); path.addCurve(to: CGPoint(x: 18,y: 25),control1: CGPoint(x: 16,y: 32),control2: CGPoint(x: 22,y: 29))
                path.addLine(to: CGPoint(x: 14,y: 18)); path.addLine(to: CGPoint(x: 19,y: 18))
                path.addQuadCurve(to: CGPoint(x: 20,y: 14),control: CGPoint(x: 23,y: 18)); path.closeSubpath()
            case .kite:
                path.addLines(between: points([(3,3),(5,25),(10,19),(16,28),(19,25),(13,17),(21,16)])); path.closeSubpath()
            case .chevron:
                path.addLines(between: points([(3,3),(3,25),(8,18),(13,29),(17,27),(12,16),(22,17),(12,10),(8,13)])); path.closeSubpath()
            case .leaf:
                path.move(to: CGPoint(x: 3,y: 3))
                path.addCurve(to: CGPoint(x: 10,y: 26),control1: CGPoint(x: 2,y: 20),control2: CGPoint(x: 5,y: 22))
                path.addQuadCurve(to: CGPoint(x: 17,y: 28),control: CGPoint(x: 18,y: 29))
                path.addLine(to: CGPoint(x: 12,y: 19))
                path.addCurve(to: CGPoint(x: 3,y: 3),control1: CGPoint(x: 27,y: 19),control2: CGPoint(x: 18,y: 7)); path.closeSubpath()
            case .orbit:
                path.addLines(between: points([(3,3),(3,22),(9,17),(14,22),(17,19),(12,14),(21,14)])); path.closeSubpath()
                path.addEllipse(in: CGRect(x: 10,y: 21.5,width: 7.5,height: 7.5))
            case .facet:
                path.addLines(between: points([(3,3),(3,25),(8,22),(11,29),(16,26),(13,19),(21,19),(18,14),(9,7)])); path.closeSubpath()
            case .technical:
                path.addLines(between: points([(3,3),(3,26),(7,20),(11,28),(14,26),(10,17),(20,17)])); path.closeSubpath()
                path.addPath(polygon(points([(5,9),(5,20),(12,16)])))
            case .minimal:
                path.addLines(between: points([(3,3),(5,25),(10,18),(20,16)])); path.closeSubpath()
            case .accessible:
                path.addLines(between: points([(3,3),(3,27),(8,22),(12,29),(19,26),(15,19),(21,19)])); path.closeSubpath()
            }
        }
        paint(path,evenOdd: geometry == .cutPaper || geometry == .technical)
    case .pointer:
        let finger: CGFloat = (alternate ? 1.35 : 1.85)+index*0.035
        let left: CGFloat = 3.5+index*0.15, right: CGFloat = 24-index*0.06
        path.move(to: CGPoint(x: 12,y: 3))
        if angular {
            path.addLines(between: [CGPoint(x: 12-finger,y: 5),CGPoint(x: 12-finger,y: 17),CGPoint(x: left+1,y: 14),CGPoint(x: left,y: 17)])
        } else {
            path.addCurve(to: CGPoint(x: 12-finger,y: 6),control1: CGPoint(x: 12-finger,y: 3),control2: CGPoint(x: 12-finger,y: 4))
            path.addLine(to: CGPoint(x: 12-finger,y: 17))
            path.addCurve(to: CGPoint(x: left,y: 17),control1: CGPoint(x: left,y: 10+index*0.13),control2: CGPoint(x: left-1,y: 14))
        }
        path.addLine(to: CGPoint(x: 8+index*0.08,y: 25))
        path.addLine(to: CGPoint(x: 9,y: alternate ? 27 : 29)); path.addLine(to: CGPoint(x: 21-index*0.08,y: alternate ? 27 : 29))
        path.addQuadCurve(to: CGPoint(x: right,y: 18),control: CGPoint(x: right,y: 26))
        for (x,y) in [(21.5-index*0.04,CGFloat(14)),(18.5,11+index*0.08),(15.4,9)] {
            if angular { path.addLine(to: CGPoint(x: x,y: y)); path.addLine(to: CGPoint(x: x-2.3,y: y+1)) }
            else { path.addQuadCurve(to: CGPoint(x: x-2.3,y: y+1),control: CGPoint(x: x,y: y-3)) }
        }
        path.addLine(to: CGPoint(x: 12+finger,y: 6))
        path.addQuadCurve(to: CGPoint(x: 12,y: 3),control: CGPoint(x: 12+finger,y: 3)); path.closeSubpath()
        paint(path,hand: true)
        c.setStrokeColor(color(preset.handOutline)); c.setLineWidth(0.7)
        for x: CGFloat in [16,19.5] { c.move(to: CGPoint(x: x,y: 15)); c.addLine(to: CGPoint(x: x,y: 19+index*0.08)) }; c.strokePath()
        if geometry == .orbit { c.setLineWidth(1); c.strokeEllipse(in: CGRect(x: 12,y: 22,width: 5,height: 5)) }
    case .text:
        let cap: CGFloat = (alternate ? 3 : 4.5)+index*0.15
        let top: CGFloat = 4+index*0.12, bottom: CGFloat = 28-index*0.09
        path.move(to: CGPoint(x: 12,y: top)); path.addLine(to: CGPoint(x: 12,y: bottom))
        for y in [top,bottom] {
            path.move(to: CGPoint(x: 12-cap,y: y)); path.addLine(to: CGPoint(x: 12+cap,y: y))
            if !alternate && [.classic,.rounded,.leaf,.pill].contains(geometry) {
                path.move(to: CGPoint(x: 12-cap,y: y+(y<16 ? 2 : -2)))
                path.addQuadCurve(to: CGPoint(x: 12+cap,y: y+(y<16 ? 2 : -2)),control: CGPoint(x: 12,y: y+(y<16 ? -2 : 2)))
            }
        }
        stroke(path,lineWidth: geometry == .accessible ? 2.8 : 1+index*0.055)
    case .resizeHorizontal,.resizeVertical,.resizeDiagonalNWSE,.resizeDiagonalNESW:
        c.saveGState(); c.translateBy(x: 16,y: 16)
        switch style { case .resizeVertical: c.rotate(by: .pi/2); case .resizeDiagonalNWSE: c.rotate(by: .pi/4); case .resizeDiagonalNESW: c.rotate(by: -.pi/4); default: break }
        c.translateBy(x: -16,y: -16)
        let tip: CGFloat = 4+index*0.1, head: CGFloat = 4+index*0.13, neck: CGFloat = 10+index*0.08
        if alternate {
            for sign: CGFloat in [-1,1] {
                path.move(to: CGPoint(x: 16+sign*(16-tip-head),y: 16-head))
                path.addLine(to: CGPoint(x: 16+sign*(16-tip),y: 16))
                path.addLine(to: CGPoint(x: 16+sign*(16-tip-head),y: 16+head))
            }
            path.move(to: CGPoint(x: 12,y: 16)); path.addLine(to: CGPoint(x: 20,y: 16)); stroke(path,lineWidth: 1.3+index*0.07)
        } else {
            let shaft: CGFloat = 1.5+index*0.08
            path.addLines(between: [CGPoint(x: tip,y: 16),CGPoint(x: neck,y: 16-head),CGPoint(x: neck,y: 16-shaft),CGPoint(x: 32-neck,y: 16-shaft),CGPoint(x: 32-neck,y: 16-head),CGPoint(x: 32-tip,y: 16),CGPoint(x: 32-neck,y: 16+head),CGPoint(x: 32-neck,y: 16+shaft),CGPoint(x: neck,y: 16+shaft),CGPoint(x: neck,y: 16+head)]); path.closeSubpath()
            paint(path)
        }
        c.restoreGState()
    case .openHand,.closedHand:
        let spread: CGFloat = (alternate ? 0.7 : 0.87)+index*0.005
        c.saveGState(); c.translateBy(x: 16,y: 16); c.scaleBy(x: spread,y: 0.88+index*0.004); c.translateBy(x: -16,y: -16)
        if style == .openHand {
            path.move(to: CGPoint(x: 8,y: 18)); path.addLine(to: CGPoint(x: 5,y: 14))
            path.addQuadCurve(to: CGPoint(x: 3,y: 17),control: CGPoint(x: 1,y: 12))
            path.addLine(to: CGPoint(x: 9,y: 26)); path.addLine(to: CGPoint(x: 12,y: 29)); path.addLine(to: CGPoint(x: 23,y: 29))
            path.addQuadCurve(to: CGPoint(x: 27,y: 21),control: CGPoint(x: 28,y: 27))
            for (x,y) in [(CGFloat(26),9+index*0.06),(21,5+index*0.1),(16,4+index*0.03),(11,7+index*0.09)] {
                path.addLine(to: CGPoint(x: x+1.5,y: y+1.5))
                if angular { path.addLine(to: CGPoint(x: x,y: y)); path.addLine(to: CGPoint(x: x-1.5,y: y+1.5)) }
                else { path.addCurve(to: CGPoint(x: x-1.5,y: y+1.5),control1: CGPoint(x: x+1.5,y: y-1.5),control2: CGPoint(x: x-1.5,y: y-1.5)) }
                path.addLine(to: CGPoint(x: x-2,y: 17))
            }
        } else {
            path.addLines(between: points([(5,15),(7,10),(10,8),(13,9),(16,7),(19,9),(22,8),(26,12),(27,21),(23,28),(11,28),(7,24),(3,19),(4,16),(7,16),(12,20)]))
        }
        path.closeSubpath(); paint(path,hand: true)
        c.setStrokeColor(color(preset.handOutline)); c.setLineWidth(0.75+index*0.025)
        if style == .closedHand { for x: CGFloat in [11,16,21] { c.move(to: CGPoint(x: x,y: 11)); c.addLine(to: CGPoint(x: x,y: alternate ? 18 : 16)) } }
        c.move(to: CGPoint(x: 12,y: 23)); c.addQuadCurve(to: CGPoint(x: 22,y: 22),control: CGPoint(x: 18,y: 19+index*0.15)); c.strokePath()
        if geometry == .pill || geometry == .accessible { c.setLineWidth(1.2); c.move(to: CGPoint(x: 12,y: 26)); c.addLine(to: CGPoint(x: 22,y: 26)); c.strokePath() }
        c.restoreGState()
    case .crosshair:
        let reach: CGFloat = 8+index*0.33, gap: CGFloat = alternate ? 3 : 0
        for axis in 0..<2 {
            for sign: CGFloat in [-1,1] {
                let a = CGPoint(x: 16+sign*gap,y: 16), b = CGPoint(x: 16+sign*reach,y: 16)
                path.move(to: axis == 0 ? a : CGPoint(x: a.y,y: a.x)); path.addLine(to: axis == 0 ? b : CGPoint(x: b.y,y: b.x))
            }
        }
        stroke(path,lineWidth: 0.8+index*0.09)
        c.setFillColor(color(preset.arrowFill)); c.fillEllipse(in: CGRect(x: 15,y: 15,width: 2,height: 2))
        if geometry == .orbit { c.setStrokeColor(color(preset.arrowFill)); c.setLineWidth(1); c.strokeEllipse(in: CGRect(x: 9,y: 9,width: 14,height: 14)) }
    case .notAllowed:
        let radius: CGFloat = 9+index*0.17
        if alternate {
            for i in 0..<8 {
                let angle = (CGFloat(i)+0.5) * CGFloat.pi / 4
                let point = CGPoint(x: 16+radius*cos(angle),y: 16+radius*sin(angle))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        } else { path.addEllipse(in: CGRect(x: 16-radius,y: 16-radius,width: radius*2,height: radius*2)) }
        path.move(to: CGPoint(x: 16-radius*0.7,y: 16-radius*0.7)); path.addLine(to: CGPoint(x: 16+radius*0.7,y: 16+radius*0.7))
        stroke(path,lineWidth: 1.4+index*0.05)
    case .touch:
        let radius: CGFloat = (pressed ? 8 : 11)+index*0.035
        if preset.id == "touch" {
            // Feathered concentric fills are authored vectors, with a denser press.
            for ring in stride(from: 4,through: 0,by: -1) {
                c.setFillColor(CGColor(gray: 1,alpha: pressed ? 0.07 : 0.04))
                let r = radius+CGFloat(ring)*0.35
                c.fillEllipse(in: CGRect(x: 16-r,y: 16-r,width: r*2,height: r*2))
            }
            c.setFillColor(CGColor(gray: pressed ? 0.15 : 1,alpha: pressed ? 0.65 : 0.22))
            c.fillEllipse(in: CGRect(x: 16-radius,y: 16-radius,width: radius*2,height: radius*2))
            c.setStrokeColor(color(preset.touchOutline)); c.setLineWidth(1.2)
            c.strokeEllipse(in: CGRect(x: 16-radius,y: 16-radius,width: radius*2,height: radius*2))
            if alternate { c.setLineWidth(1); c.strokeEllipse(in: CGRect(x: 12,y: 12,width: 8,height: 8)) }
        } else {
            let figure = CGMutablePath()
            if angular { figure.addPath(polygon([CGPoint(x: 16,y: 16-radius),CGPoint(x: 16+radius,y: 16),CGPoint(x: 16,y: 16+radius),CGPoint(x: 16-radius,y: 16)])) }
            else { figure.addEllipse(in: CGRect(x: 16-radius,y: 16-radius,width: radius*2,height: radius*2)) }
            c.setFillColor(color(preset.touchFill)); c.addPath(figure); c.fillPath()
            let outlineIsLight = preset.touchOutline.x+preset.touchOutline.y+preset.touchOutline.z > 1.5
            c.setStrokeColor(CGColor(gray: outlineIsLight ? 0.05 : 0.95,alpha: 0.65)); c.setLineWidth(2.2+index*0.05); c.addPath(figure); c.strokePath()
            c.setStrokeColor(color(preset.touchOutline)); c.setLineWidth(1+index*0.05); c.addPath(figure); c.strokePath()
            if alternate { c.setLineWidth(1); c.strokeEllipse(in: CGRect(x: 11,y: 11,width: 10,height: 10)) }
        }
    }
}
