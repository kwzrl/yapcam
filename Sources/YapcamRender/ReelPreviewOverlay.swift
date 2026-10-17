import AppKit
import SwiftUI

public enum ReelPreviewMode: String, CaseIterable, Sendable, Codable {
    case off, instagram, tiktok
    public var title: String {
        switch self { case .off: "Off"; case .instagram: "Instagram"; case .tiktok: "TikTok" }
    }
}

/// Approximate interface occupancy, authored here. Platform UI changes by device
/// and account; these guides indicate risky regions rather than guaranteeing fit.
/// Coordinates have a top-left origin, independent of drawable pixel density.
public struct ReelSafeAreaLayout: Equatable, Sendable {
    public let safeRect: CGRect
    public let topRegion: CGRect
    public let bottomRegion: CGRect
    public let actionRegion: CGRect

    public init?(mode: ReelPreviewMode, bounds: CGRect) {
        guard mode != .off, [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite),
              bounds.size.width > 0, bounds.size.height > 0,
              bounds.size.height > bounds.size.width else { return nil }   // reels are portrait: no guides over 16:9 or square
        let top: CGFloat = mode == .instagram ? 0.10 : 0.12
        let bottom: CGFloat = mode == .instagram ? 0.22 : 0.24
        let right: CGFloat = mode == .instagram ? 0.16 : 0.18
        func rect(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat) -> CGRect {
            CGRect(x: bounds.minX+x*bounds.width,y: bounds.minY+y*bounds.height,width: w*bounds.width,height: h*bounds.height)
        }
        safeRect=rect(0.05,top,0.95-right,1-top-bottom)
        topRegion=rect(0,0,1,top)
        bottomRegion=rect(0,1-bottom,1,bottom)
        actionRegion=rect(1-right,0.38,right,0.62-bottom)
    }

    func draw(in context: CGContext, bounds: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        context.setFillColor(CGColor(gray: 0,alpha: 0.32))
        context.fill(topRegion); context.fill(bottomRegion); context.fill(actionRegion)
        let unit=min(bounds.width,bounds.height)
        context.setStrokeColor(CGColor(red: 0.4,green: 0.9,blue: 0.94,alpha: 0.9))
        context.setLineWidth(max(1,unit*0.003))
        context.setLineDash(phase: 0,lengths: [unit*0.018,unit*0.012])
        context.stroke(safeRect)
        context.setLineDash(phase: 0,lengths: [])
        // Generic interface silhouettes: header, action rail and caption rows.
        // No platform logos, fonts, screenshots or reference assets are used.
        context.setFillColor(CGColor(gray: 1,alpha: 0.72))
        context.setStrokeColor(CGColor(gray: 1,alpha: 0.8))
        func bar(x: CGFloat,y: CGFloat,width: CGFloat,height: CGFloat) {
            context.addPath(CGPath(roundedRect: CGRect(x: x,y: y,width: width,height: height),
                cornerWidth: height/2,cornerHeight: height/2,transform: nil)); context.fillPath()
        }
        bar(x: bounds.minX+unit*0.06,y: topRegion.midY-unit*0.01,width: bounds.width*0.28,height: unit*0.02)
        for row in 0..<4 {
            let radius=unit*0.035
            let center=CGPoint(x: actionRegion.midX,y: actionRegion.minY+actionRegion.height*(CGFloat(row)+0.5)/4)
            context.strokeEllipse(in: CGRect(x: center.x-radius,y: center.y-radius,width: radius*2,height: radius*2))
        }
        for row in 0..<3 {
            bar(x: bounds.minX+unit*0.06,y: bottomRegion.minY+bottomRegion.height*(0.22+CGFloat(row)*0.19),
                width: bounds.width*(row == 0 ? 0.3 : row == 1 ? 0.64 : 0.48),height: unit*0.018)
        }
    }
}

/// A separate view above the video. It is never a RenderLayer, compositor input,
/// drawable texture or ExportSettings field, so exporting cannot include it.
public struct ReelSafeAreaOverlay: NSViewRepresentable {
    public var mode: ReelPreviewMode
    public init(mode: ReelPreviewMode) { self.mode=mode }
    public func makeNSView(context: Context) -> NSView { ReelOverlayView(mode: mode) }
    public func updateNSView(_ nsView: NSView,context: Context) { (nsView as? ReelOverlayView)?.mode=mode }
}

@MainActor final class ReelOverlayView: NSView {
    var mode: ReelPreviewMode { didSet { isHidden=mode == .off; needsDisplay=true } }
    init(mode: ReelPreviewMode = .off) {
        self.mode=mode
        super.init(frame: .zero)
        isHidden=mode == .off
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context=NSGraphicsContext.current?.cgContext,
              let layout=ReelSafeAreaLayout(mode: mode,bounds: bounds) else { return }
        layout.draw(in: context,bounds: bounds)
    }
}
