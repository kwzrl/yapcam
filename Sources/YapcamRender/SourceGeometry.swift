import CoreGraphics
import simd

/// Normalize an AVFoundation track's preferred transform without resampling its VFR frames.
struct SourceGeometry {
    let nativeSize: CGSize
    let transform: CGAffineTransform
    let displayRect: CGRect
    var displaySize: CGSize { displayRect.size }
    var rowX: SIMD4<Float> {
        let inverse=transform.inverted()
        return SIMD4(Float(inverse.a*displayRect.width/nativeSize.width),Float(inverse.c*displayRect.height/nativeSize.width),Float((inverse.a*displayRect.minX+inverse.c*displayRect.minY+inverse.tx)/nativeSize.width),0)
    }
    var rowY: SIMD4<Float> {
        let inverse=transform.inverted()
        return SIMD4(Float(inverse.b*displayRect.width/nativeSize.height),Float(inverse.d*displayRect.height/nativeSize.height),Float((inverse.b*displayRect.minX+inverse.d*displayRect.minY+inverse.ty)/nativeSize.height),0)
    }
    init(size: CGSize,transform: CGAffineTransform = .identity) {
        nativeSize=size; self.transform=transform
        displayRect=CGRect(origin: .zero,size: size).applying(transform)
    }
    func displayRect(fromNativeNormalized rect: CGRect) -> CGRect {
        let pixels=CGRect(x: rect.minX*nativeSize.width,y: rect.minY*nativeSize.height,width: rect.width*nativeSize.width,height: rect.height*nativeSize.height).applying(transform)
        return CGRect(x: (pixels.minX-displayRect.minX)/displayRect.width,y: (pixels.minY-displayRect.minY)/displayRect.height,width: pixels.width/displayRect.width,height: pixels.height/displayRect.height)
    }
}
