// Renders App/Branding/AppIcon.svg into the AppIcon asset catalog PNGs.
// Usage (from the repo root): swift scripts/render-app-icon.swift [svg] [out dir] [sizes…]
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let svg = args.count > 0 ? args[0] : "App/Branding/AppIcon.svg"
let outDir = args.count > 1 ? args[1] : "App/EmberStudio/Assets.xcassets/AppIcon.appiconset"
let sizes = args.count > 2 ? args[2...].compactMap { Int($0) } : [16, 32, 128, 256, 512, 1024]

guard let image = NSImage(contentsOf: URL(fileURLWithPath: svg)) else {
    FileHandle.standardError.write("cannot load \(svg)\n".data(using: .utf8)!)
    exit(1)
}
for px in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let url = URL(fileURLWithPath: "\(outDir)/icon_\(px).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}
