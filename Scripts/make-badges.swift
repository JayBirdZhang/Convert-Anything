// Draws the README badges (docs/badge-*.svg) in the same system font as the download button,
// sized to the real text widths. make-release.sh runs this with the version being released.
//
//   swift Scripts/make-badges.swift <version> <minimum macOS>      e.g.  swift Scripts/make-badges.swift 1.3 14.0
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make-badges.swift <version> <minimum macOS>\n".data(using: .utf8)!)
    exit(1)
}
let version = args[1]
// "14.0" → "14+", "14.2" → "14.2+"
let minMacOS = (args[2].hasSuffix(".0") ? String(args[2].dropLast(2)) : args[2]) + "+"
let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../docs").standardized.path

func width(_ s: String, bold: Bool) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 13, weight: bold ? .semibold : .medium)
    return ceil((s as NSString).size(withAttributes: [.font: font]).width)
}

let badges: [(file: String, label: String, value: String, color: String)] = [
    ("release", "Release", "v\(version)", "#E8604C"),
    ("macos", "macOS", minMacOS, "#3B82F6"),
    ("chip", "Runs On", "Apple Silicon + Intel", "#1FA39A"),
    ("license", "License", "GPL-3.0", "#8B5CF6"),
]
let pad: CGFloat = 11, height = 28
let fontStack = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif"

for b in badges {
    let lw = Int(width(b.label, bold: false)), vw = Int(width(b.value, bold: true))
    let left = lw + Int(pad * 2), right = vw + Int(pad * 2), total = left + right
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(total)" height="\(height)" viewBox="0 0 \(total) \(height)">
      <title>\(b.label): \(b.value)</title>
      <clipPath id="r"><rect width="\(total)" height="\(height)" rx="2"/></clipPath>
      <g clip-path="url(#r)">
        <rect width="\(left)" height="\(height)" fill="#1E2540"/>
        <rect x="\(left)" width="\(right)" height="\(height)" fill="\(b.color)"/>
      </g>
      <g font-family="\(fontStack)" font-size="13" font-weight="500" fill="#fff">
        <text x="\(Int(pad))" y="18.5" fill-opacity="0.82" textLength="\(lw)" lengthAdjust="spacingAndGlyphs">\(b.label)</text>
        <text x="\(left + Int(pad))" y="18.5" font-weight="600" textLength="\(vw)" lengthAdjust="spacingAndGlyphs">\(b.value)</text>
      </g>
    </svg>

    """
    try! svg.write(toFile: "\(docs)/badge-\(b.file).svg", atomically: true, encoding: .utf8)
}
print("Badges → docs/badge-*.svg (v\(version), macOS \(minMacOS))")
