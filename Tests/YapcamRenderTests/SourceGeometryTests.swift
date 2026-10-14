import XCTest
@testable import YapcamRender
import CoreGraphics

final class SourceGeometryTests: XCTestCase {
    func testQuarterTurnMapsDisplayCornersBackToNativePixels() {
        let geometry=SourceGeometry(size: CGSize(width: 320,height: 200),transform: CGAffineTransform(a: 0,b: 1,c: -1,d: 0,tx: 200,ty: 0))
        XCTAssertEqual(geometry.displaySize,CGSize(width: 200,height: 320))
        let x=geometry.rowX,y=geometry.rowY
        func mapped(_ a: Float,_ b: Float) -> SIMD2<Float> { SIMD2(a*x.x+b*x.y+x.z,a*y.x+b*y.y+y.z) }
        XCTAssertEqual(mapped(0,0),SIMD2(0,1))
        XCTAssertEqual(mapped(1,0),SIMD2(0,0))
        XCTAssertEqual(mapped(0,1),SIMD2(1,1))
        XCTAssertEqual(mapped(1,1),SIMD2(1,0))
    }
    func testFaceRectUsesDisplayedCoordinatesAndIdentityStaysExact() {
        let identity=SourceGeometry(size: CGSize(width: 1920,height: 1080))
        XCTAssertEqual(identity.rowX,SIMD4(1,0,0,0)); XCTAssertEqual(identity.rowY,SIMD4(0,1,0,0))
        let rectangle=CGRect(x: 0.2,y: 0.3,width: 0.1,height: 0.2)
        let rotated=SourceGeometry(size: CGSize(width: 320,height: 200),transform: CGAffineTransform(a: 0,b: 1,c: -1,d: 0,tx: 200,ty: 0)).displayRect(fromNativeNormalized: rectangle)
        XCTAssertEqual(rotated.minX,0.5,accuracy: 0.000_001); XCTAssertEqual(rotated.minY,0.2,accuracy: 0.000_001)
        XCTAssertEqual(rotated.width,0.2,accuracy: 0.000_001); XCTAssertEqual(rotated.height,0.1,accuracy: 0.000_001)
    }
}
