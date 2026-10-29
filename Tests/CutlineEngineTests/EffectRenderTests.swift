import CoreImage
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

/// Red, green, blue and alpha of one pixel, 0–255, with y measured from the top.
private func pixel(_ img: CIImage, _ x: CGFloat, _ yFromTop: CGFloat, height: CGFloat) -> [Int] {
    var px = [UInt8](repeating: 0, count: 4)
    context.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: height - yFromTop - 1, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return px.map(Int.init)
}

private func square() -> CIImage {
    CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
}

@Test func dropShadowDarkensBelowTheShape() {
    let ctx = EffectRenderer.Context(unit: 200, time: 0, opaque: false)
    let shadowed = EffectRenderer.apply([Effect(id: "s", type: "stylize.drop_shadow", params: ["y": .number(0.1), "radius": .number(0.02), "opacity": .number(1)])], to: square(), context: ctx) { _, _ in nil }
    let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: -100, y: -100, width: 400, height: 400))
    let out = shadowed.composited(over: gray)
    // Just below the square's bottom edge (y = -10 in CI space, i.e. 210 from the top of a 200 tall frame).
    let below = pixel(out, 100, 210, height: 200)
    #expect(below[0] < 100, "shadow pixel \(below)")
}

@Test func everyCatalogEffectRenders() {
    let ctx = EffectRenderer.Context(unit: 200, time: 0.5, opaque: true)
    let img = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 120))
    for type in EffectCatalog.all {
        let out = EffectRenderer.apply([Effect(id: "e", type: type.id)], to: img, context: ctx) { _, _ in nil }
        #expect(!out.extent.isInfinite, "\(type.id) produced an infinite image")
        let px = pixel(out.cropped(to: img.extent), 100, 60, height: 120)
        #expect(px[3] > 0 || type.category == "mask", "\(type.id) produced nothing at the center: \(px)")
    }
}

@Test func maskKeepsInsideOnly() {
    let ctx = EffectRenderer.Context(unit: 200, time: 0, opaque: true)
    let out = EffectRenderer.apply([Effect(id: "m", type: "mask.rect", params: ["width": .number(0.5), "height": .number(0.5)])], to: square(), context: ctx) { _, _ in nil }
    #expect(pixel(out, 100, 100, height: 200)[3] == 255)
    #expect(pixel(out, 10, 10, height: 200)[3] == 0)
}
