import AppKit

@MainActor
enum FinderDocumentCreator {
    private struct Specification {
        let defaultName: String
        let applicationBundleIdentifiers: [String]
        let templateName: String
        let fallback: OfficeOpenXMLTemplate.Kind?
    }

    static func create(
        _ action: FinderEnhancementRequest.Action,
        in directory: URL
    ) throws {
        let specification = try specification(for: action)
        guard let application = application(
            bundleIdentifiers: specification.applicationBundleIdentifiers
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try templateData(
            for: specification,
            application: application
        )
        let created = try FinderEnhancementRequest.createUntitledFile(
            in: directory,
            name: specification.defaultName,
            contents: data
        )
        open(created, in: application)
    }

    private static func specification(
        for action: FinderEnhancementRequest.Action
    ) throws -> Specification {
        switch action {
        case .newWord:
            return Specification(
                defaultName: L10n.shared.string("未命名文档.docx"),
                applicationBundleIdentifiers: ["com.microsoft.Word"],
                templateName: "newfile.docx",
                fallback: .word
            )
        case .newExcel:
            return Specification(
                defaultName: L10n.shared.string("未命名工作簿.xlsx"),
                applicationBundleIdentifiers: ["com.microsoft.Excel"],
                templateName: "newfile.xlsx",
                fallback: .excel
            )
        case .newPowerPoint:
            return Specification(
                defaultName: L10n.shared.string("未命名演示文稿.pptx"),
                applicationBundleIdentifiers: ["com.microsoft.Powerpoint"],
                templateName: "newfile.pptx",
                fallback: .powerpoint
            )
        case .newWPSWriter:
            return Specification(
                defaultName: L10n.shared.string("未命名文档.wps"),
                applicationBundleIdentifiers: ["com.kingsoft.wpsoffice.mac"],
                templateName: "newfile.wps",
                fallback: nil
            )
        case .newWPSSpreadsheet:
            return Specification(
                defaultName: L10n.shared.string("未命名表格.et"),
                applicationBundleIdentifiers: ["com.kingsoft.wpsoffice.mac"],
                templateName: "newfile.et",
                fallback: nil
            )
        case .newWPSPresentation:
            return Specification(
                defaultName: L10n.shared.string("未命名演示.dps"),
                applicationBundleIdentifiers: ["com.kingsoft.wpsoffice.mac"],
                templateName: "newfile.dps",
                fallback: nil
            )
        case .newFile, .copyPath, .terminal:
            throw CocoaError(.featureUnsupported)
        }
    }

    private static func templateData(
        for specification: Specification,
        application appURL: URL
    ) throws -> Data {
        if let data = installedTemplate(
            named: specification.templateName,
            in: appURL
        ) {
            return data
        }
        if let wps = application(
            bundleIdentifiers: ["com.kingsoft.wpsoffice.mac"]
        ), let data = installedTemplate(
            named: specification.templateName,
            in: wps
        ) {
            return data
        }
        if let fallback = specification.fallback {
            return try OfficeOpenXMLTemplate.data(for: fallback)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func installedTemplate(
        named name: String,
        in application: URL
    ) -> Data? {
        let resources = application.appendingPathComponent("Contents/Resources")
        let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true
            ? "zh_CN"
            : "en_US"
        let candidates = [
            resources.appendingPathComponent(
                "office6/mui/\(language)/templates/\(name)"
            ),
            resources.appendingPathComponent(
                "office6/mui/default/templates/\(name)"
            ),
            resources.appendingPathComponent("templates/\(name)"),
        ]
        for candidate in candidates where FileManager.default.fileExists(
            atPath: candidate.path
        ) {
            return try? Data(contentsOf: candidate)
        }
        return nil
    }

    private static func application(bundleIdentifiers: [String]) -> URL? {
        bundleIdentifiers.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
    }

    private static func open(_ file: URL, in application: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = true
        NSWorkspace.shared.open(
            [file],
            withApplicationAt: application,
            configuration: configuration
        ) { _, error in
            guard error != nil else { return }
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error!).runModal()
            }
        }
    }
}

enum OfficeOpenXMLTemplate {
    enum Kind {
        case word
        case excel
        case powerpoint
    }

    static func data(for kind: Kind) throws -> Data {
        let entries: [(String, String)]
        switch kind {
        case .word:
            entries = wordEntries
        case .excel:
            entries = excelEntries
        case .powerpoint:
            entries = powerpointEntries
        }
        return try StoredZIPArchive.make(
            entries: entries.map { ($0.0, Data($0.1.utf8)) }
        )
    }

    private static let wordEntries: [(String, String)] = [
        (
            "[Content_Types].xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """
        ),
        (
            "_rels/.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """
        ),
        (
            "word/document.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body>
                <w:p/>
                <w:sectPr>
                  <w:pgSz w:w="12240" w:h="15840"/>
                  <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>
                </w:sectPr>
              </w:body>
            </w:document>
            """
        ),
    ]

    private static let excelEntries: [(String, String)] = [
        (
            "[Content_Types].xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
              <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
              <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """
        ),
        (
            "_rels/.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """
        ),
        (
            "xl/workbook.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets>
                <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
              </sheets>
            </workbook>
            """
        ),
        (
            "xl/_rels/workbook.xml.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """
        ),
        (
            "xl/worksheets/sheet1.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData/>
            </worksheet>
            """
        ),
        (
            "xl/styles.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
              <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
              <borders count="1"><border/></borders>
              <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
              <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
            </styleSheet>
            """
        ),
    ]

    private static let powerpointEntries: [(String, String)] = [
        (
            "[Content_Types].xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
              <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
              <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
              <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
              <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
            </Types>
            """
        ),
        (
            "_rels/.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
            </Relationships>
            """
        ),
        (
            "ppt/presentation.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
              <p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>
              <p:sldSz cx="12192000" cy="6858000" type="screen16x9"/>
              <p:notesSz cx="6858000" cy="9144000"/>
            </p:presentation>
            """
        ),
        (
            "ppt/_rels/presentation.xml.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
            </Relationships>
            """
        ),
        (
            "ppt/slides/slide1.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                   xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                   xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:cSld><p:spTree>
                <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
                <p:grpSpPr/>
              </p:spTree></p:cSld>
              <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            </p:sld>
            """
        ),
        (
            "ppt/slides/_rels/slide1.xml.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            </Relationships>
            """
        ),
        (
            "ppt/slideLayouts/slideLayout1.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                         xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                         xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                         type="blank">
              <p:cSld name="Blank"><p:spTree>
                <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
                <p:grpSpPr/>
              </p:spTree></p:cSld>
              <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            </p:sldLayout>
            """
        ),
        (
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
            </Relationships>
            """
        ),
        (
            "ppt/slideMasters/slideMaster1.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                         xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                         xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:cSld><p:spTree>
                <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
                <p:grpSpPr/>
              </p:spTree></p:cSld>
              <p:clrMap accent1="accent1" accent2="accent2" accent3="accent3"
                        accent4="accent4" accent5="accent5" accent6="accent6"
                        bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink"
                        tx1="dk1" tx2="dk2"/>
              <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
              <p:txStyles>
                <p:titleStyle/>
                <p:bodyStyle/>
                <p:otherStyle/>
              </p:txStyles>
            </p:sldMaster>
            """
        ),
        (
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
            </Relationships>
            """
        ),
        (
            "ppt/theme/theme1.xml",
            """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">
              <a:themeElements>
                <a:clrScheme name="Office">
                  <a:dk1><a:srgbClr val="000000"/></a:dk1>
                  <a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
                  <a:dk2><a:srgbClr val="44546A"/></a:dk2>
                  <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
                  <a:accent1><a:srgbClr val="4472C4"/></a:accent1>
                  <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
                  <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
                  <a:accent4><a:srgbClr val="FFC000"/></a:accent4>
                  <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>
                  <a:accent6><a:srgbClr val="70AD47"/></a:accent6>
                  <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
                  <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
                </a:clrScheme>
                <a:fontScheme name="Office">
                  <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
                  <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
                </a:fontScheme>
                <a:fmtScheme name="Office">
                  <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
                  <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
                  <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
                  <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
                </a:fmtScheme>
              </a:themeElements>
            </a:theme>
            """
        ),
    ]
}

private enum StoredZIPArchive {
    struct Entry {
        let name: Data
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    static func make(entries: [(String, Data)]) throws -> Data {
        var output = Data()
        var central: [Entry] = []
        for (name, data) in entries {
            guard let nameData = name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max),
                  data.count <= Int(UInt32.max),
                  output.count <= Int(UInt32.max) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let crc = CRC32.checksum(data)
            let offset = UInt32(output.count)
            output.appendLittleEndian(UInt32(0x04034B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0x0800))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(crc)
            output.appendLittleEndian(UInt32(data.count))
            output.appendLittleEndian(UInt32(data.count))
            output.appendLittleEndian(UInt16(nameData.count))
            output.appendLittleEndian(UInt16(0))
            output.append(nameData)
            output.append(data)
            central.append(Entry(
                name: nameData,
                data: data,
                crc: crc,
                offset: offset
            ))
        }
        let centralOffset = UInt32(output.count)
        for entry in central {
            output.appendLittleEndian(UInt32(0x02014B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0x0800))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(entry.crc)
            output.appendLittleEndian(UInt32(entry.data.count))
            output.appendLittleEndian(UInt32(entry.data.count))
            output.appendLittleEndian(UInt16(entry.name.count))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt32(0))
            output.appendLittleEndian(entry.offset)
            output.append(entry.name)
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.appendLittleEndian(UInt32(0x06054B50))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(central.count))
        output.appendLittleEndian(UInt16(central.count))
        output.appendLittleEndian(centralSize)
        output.appendLittleEndian(centralOffset)
        output.appendLittleEndian(UInt16(0))
        return output
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1
                ? (crc >> 1) ^ 0xEDB88320
                : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in data {
            value = (value >> 8) ^ table[Int((value ^ UInt32(byte)) & 0xFF)]
        }
        return value ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
