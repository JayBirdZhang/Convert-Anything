import Foundation
import PDFKit

/// Runs LibreOffice invisibly to convert Office files.
nonisolated enum LibreOffice {
    static var path: String? {
        let apps = ["/Applications", "\(NSHomeDirectory())/Applications"].map { "\($0)/LibreOffice.app/Contents/MacOS/soffice" }
        return Tools.path(for: "soffice") ?? apps.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Uses its own settings profile, so it never collides with a LibreOffice window you have open.
    static func convert(_ input: URL, to type: String, workDir: URL) async throws -> URL {
        guard let soffice = path else {
            throw ConversionError.missingTool("LibreOffice", brewPackage: "--cask libreoffice")
        }
        let profile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "FileConverter/LibreOfficeProfile")
        let outDir = workDir.appending(path: "libreoffice")
        try await Tools.run(soffice, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                                      "--nolockcheck", "--convert-to", type, "--outdir", outDir.path, input.path])
        let result = outDir.appending(path: input.deletingPathExtension().lastPathComponent + "." + type)
        // LibreOffice can exit successfully without writing anything when it can't read the file.
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw ConversionError.failed("LibreOffice couldn't open this file.")
        }
        return result
    }
}

/// Builds a PowerPoint file with one full-slide picture per PDF page (or a single slide for an image).
/// Slides look exactly like the source but their text isn't editable.
nonisolated enum SlideBuilder {
    private static let slideWidth = 12_192_000   // 13.33 in, PowerPoint's widescreen width, in EMUs

    static func build(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let package = request.workDir.appending(path: "pptx")
        let media = package.appending(path: "ppt/media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let sizes = try await Task.detached(priority: .utility) { () throws -> [CGSize] in
            if request.from == .pdf {
                guard let document = PDFDocument(url: request.input), document.pageCount > 0 else {
                    throw ConversionError.failed("Couldn't read this PDF.")
                }
                var sizes: [CGSize] = []
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    let image = try ImageConversion.render(page)
                    try ImageConversion.write(image, to: media.appending(path: "image\(sizes.count + 1).png"), format: .png)
                    sizes.append(CGSize(width: image.width, height: image.height))
                    progress(Double(index + 1) / Double(document.pageCount) * 0.95)
                }
                return sizes
            } else {
                let png = media.appending(path: "image1.png")
                try ImageConversion.convert(request.input, to: .png, output: png)
                guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ConversionError.failed("Couldn't read this image.")
                }
                return [CGSize(width: image.width, height: image.height)]
            }
        }.value

        // The slide shape follows the first page, e.g. 16:9 for a deck exported to PDF, portrait for a Letter page.
        let first = sizes[0]
        let slideHeight = min(max(Int(Double(slideWidth) * first.height / first.width), 914_400), 51_206_400)
        try writeParts(to: package, sizes: sizes, slideHeight: slideHeight)

        // -nw: "[Content_Types].xml" is a literal name, not a wildcard pattern.
        try await Tools.run("/usr/bin/zip", ["-q", "-X", "-nw", "-r", output.path, "[Content_Types].xml", "_rels", "ppt"],
                            currentDirectory: package)
        progress(1)
    }

    private static func writeParts(to package: URL, sizes: [CGSize], slideHeight: Int) throws {
        let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let emptyTree = #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#
        let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pml = "application/vnd.openxmlformats-officedocument.presentationml"

        func write(_ path: String, _ xml: String) throws {
            let url = package.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (header + xml).write(to: url, atomically: true, encoding: .utf8)
        }
        func rels(_ entries: [(id: String, type: String, target: String)]) -> String {
            #"<Relationships xmlns="\#(relNS)">"#
                + entries.map { #"<Relationship Id="\#($0.id)" Type="\#(relType)/\#($0.type)" Target="\#($0.target)"/>"# }.joined()
                + "</Relationships>"
        }
        let slides = 1...sizes.count

        try write("[Content_Types].xml", #"""
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/ppt/presentation.xml" ContentType="\#(pml).presentation.main+xml"/>\
            <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="\#(pml).slideMaster+xml"/>\
            <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="\#(pml).slideLayout+xml"/>\
            <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
            \#(slides.map { #"<Override PartName="/ppt/slides/slide\#($0).xml" ContentType="\#(pml).slide+xml"/>"# }.joined())\
            </Types>
            """#)
        try write("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml")]))

        try write("ppt/presentation.xml", #"""
            <p:presentation \#(ns) saveSubsetFonts="1">\
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            <p:sldIdLst>\#(slides.map { #"<p:sldId id="\#(255 + $0)" r:id="rId\#($0 + 2)"/>"# }.joined())</p:sldIdLst>\
            <p:sldSz cx="\#(slideWidth)" cy="\#(slideHeight)"/><p:notesSz cx="6858000" cy="9144000"/>\
            </p:presentation>
            """#)
        try write("ppt/_rels/presentation.xml.rels", rels(
            [("rId1", "slideMaster", "slideMasters/slideMaster1.xml"), ("rId2", "theme", "theme/theme1.xml")]
                + slides.map { ("rId\($0 + 2)", "slide", "slides/slide\($0).xml") }))

        try write("ppt/slideMasters/slideMaster1.xml", #"""
            <p:sldMaster \#(ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\
            <p:spTree>\#(emptyTree)</p:spTree></p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
            accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
            """#)
        try write("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels(
            [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]))

        try write("ppt/slideLayouts/slideLayout1.xml", #"""
            <p:sldLayout \#(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\#(emptyTree)</p:spTree></p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
            """#)
        try write("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))

        try write("ppt/theme/theme1.xml", theme)

        for (index, size) in sizes.enumerated() {
            let number = index + 1
            // Fit each picture inside the slide, centered, keeping its proportions.
            let scale = min(Double(slideWidth) / size.width, Double(slideHeight) / size.height)
            let width = Int(size.width * scale), height = Int(size.height * scale)
            let x = (slideWidth - width) / 2, y = (slideHeight - height) / 2
            try write("ppt/slides/slide\(number).xml", #"""
                <p:sld \#(ns)><p:cSld><p:spTree>\#(emptyTree)\
                <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \#(number)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
                <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
                <p:spPr><a:xfrm><a:off x="\#(x)" y="\#(y)"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm>\
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>\
                </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """#)
            try write("ppt/slides/_rels/slide\(number).xml.rels", rels(
                [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "image", "../media/image\(number).png")]))
        }
    }

    /// The minimal Office theme every presentation needs (colors, fonts and fill/line/effect styles).
    private static let theme = #"""
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements>\
        <a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
        <a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1>\
        <a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4>\
        <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink>\
        <a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>\
        <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
        <a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
        <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
        <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
        <a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
        <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """#
}
