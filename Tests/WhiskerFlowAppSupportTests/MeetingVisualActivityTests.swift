import CoreGraphics
import ImageIO
import XCTest
@testable import WhiskerFlowAppSupport

final class MeetingVisualActivityTests: XCTestCase {
  func testObservedMeetFrameWhenExplicitlyProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["WF_VISUAL_FIXTURE"] else {
      throw XCTSkip("Opt-in local frame only")
    }
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let scale = CGFloat(image.width) / 768
    let active = CGRect(x: 387 * scale, y: 110 * scale, width: 374 * scale, height: 312 * scale)
    XCTAssertTrue(MeetingVisualActivity.isSpeaking(image: image, tile: active, scale: scale))
    XCTAssertNotNil(
      MeetingVisualActivity.speakingTile(
        image: image,
        nameFrame: CGRect(x: 398 * scale, y: 398 * scale, width: 60 * scale, height: 13 * scale)))
    XCTAssertNil(
      MeetingVisualActivity.speakingTile(
        image: image,
        nameFrame: CGRect(x: 20 * scale, y: 718 * scale, width: 50 * scale, height: 13 * scale)))
    for r in [
      CGRect(x: 10, y: 111, width: 371, height: 309),
      CGRect(x: 10, y: 428, width: 371, height: 309),
      CGRect(x: 388, y: 428, width: 371, height: 309),
    ] {
      XCTAssertFalse(
        MeetingVisualActivity.isSpeaking(
          image: image,
          tile: CGRect(
            x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale),
          scale: scale))
    }
  }
  func testSecondObservedSpeakerWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["WF_VISUAL_SECOND_FIXTURE"] else { throw XCTSkip("Opt-in local frame only") }
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
    let scale = CGFloat(image.width)/768
    let name = CGRect(x:20*scale,y:717*scale,width:50*scale,height:13*scale)
    XCTAssertNotNil(MeetingVisualActivity.speakingTile(image:image,nameFrame:name))
  }
  private func frame(border: Bool, badge: Bool) -> CGImage {
    let c = CGContext(
      data: nil, width: 300, height: 220, bitsPerComponent: 8, bytesPerRow: 1200,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 300, height: 220))
    c.setStrokeColor(CGColor(red: 0.65, green: 0.78, blue: 0.97, alpha: 1))
    c.setLineWidth(3)
    if border { c.stroke(CGRect(x: 11, y: 11, width: 278, height: 198)) }
    if badge {
      c.setFillColor(CGColor(red: 0.65, green: 0.78, blue: 0.97, alpha: 1))
      c.fillEllipse(in: CGRect(x: 265, y: 185, width: 16, height: 16))
      c.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1))
      c.fill(CGRect(x: 272, y: 188, width: 2, height: 10))
    }
    return c.makeImage()!
  }
  func testRequiresBothOpposingBordersAndSameTileWaveform() {
    let tile = CGRect(x: 10, y: 10, width: 280, height: 200)
    XCTAssertTrue(
      MeetingVisualActivity.isSpeaking(image: frame(border: true, badge: true), tile: tile))
    XCTAssertFalse(
      MeetingVisualActivity.isSpeaking(image: frame(border: true, badge: false), tile: tile))
    XCTAssertFalse(
      MeetingVisualActivity.isSpeaking(image: frame(border: false, badge: true), tile: tile))
    XCTAssertFalse(
      MeetingVisualActivity.isSpeaking(image: frame(border: false, badge: false), tile: tile))
  }
  func testRejectsCroppedOrTinyTiles() {
    let image = frame(border: true, badge: true)
    XCTAssertFalse(
      MeetingVisualActivity.isSpeaking(
        image: image, tile: CGRect(x: -1, y: 10, width: 280, height: 200)))
    XCTAssertFalse(
      MeetingVisualActivity.isSpeaking(
        image: image, tile: CGRect(x: 10, y: 10, width: 30, height: 20)))
  }
  func testSpeakingTilesLocatesOutlineOnceAndIgnoresLargeFilledRegions() {
    let tiles = MeetingVisualActivity.speakingTiles(image: frame(border: true, badge: true), nameHeight: 13)
    XCTAssertEqual(tiles.count, 1)
    XCTAssertEqual(tiles.first.map { MeetingVisualActivity.isSpeaking(image: frame(border: true, badge: true), tile: $0) }, true)
    XCTAssertTrue(MeetingVisualActivity.speakingTiles(image: frame(border: true, badge: false), nameHeight: 13).isEmpty)
    // A full-frame light-blue slide is one large component, filled without a per-pixel stack.
    let c = CGContext(
      data: nil, width: 1024, height: 640, bitsPerComponent: 8, bytesPerRow: 1024 * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(red: 0.65, green: 0.78, blue: 0.97, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 1024, height: 640))
    XCTAssertTrue(MeetingVisualActivity.speakingTiles(image: c.makeImage()!, nameHeight: 13).isEmpty)
  }
}
