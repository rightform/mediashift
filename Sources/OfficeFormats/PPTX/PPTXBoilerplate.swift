import Foundation

/// The fixed parts every deck needs: one theme, one master, two layouts. Plain and neutral,
/// close to PowerPoint's own blank presentation.
enum PPTXBoilerplate {
    static let drawingNamespace = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let presentationNamespace = "http://schemas.openxmlformats.org/presentationml/2006/main"
    /// PowerPoint's built-in "Medium Style 2 - Accent 1".
    static let tableStyleID = "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"

    private static let namespaces = "xmlns:a=\"\(drawingNamespace)\" xmlns:r=\"\(OPC.officeRelationships)\" xmlns:p=\"\(presentationNamespace)\""

    static let groupHeader = """
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        """

    static let tableStyles = OPC.xmlHeader + "<a:tblStyleLst xmlns:a=\"\(drawingNamespace)\" def=\"\(tableStyleID)\"/>"

    static let masterRelationships = OPC.relationshipsXML([
        ("rId1", "\(OPC.officeRelationships)/slideLayout", "../slideLayouts/slideLayout1.xml", false),
        ("rId2", "\(OPC.officeRelationships)/slideLayout", "../slideLayouts/slideLayout2.xml", false),
        ("rId3", "\(OPC.officeRelationships)/theme", "../theme/theme1.xml", false),
    ])

    static let layoutRelationships = OPC.relationshipsXML([
        ("rId1", "\(OPC.officeRelationships)/slideMaster", "../slideMasters/slideMaster1.xml", false)
    ])

    static let theme: String = {
        let accents = ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47"]
        var colors = """
            <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
            <a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
            """
        for (index, accent) in accents.enumerated() {
            colors += "<a:accent\(index + 1)><a:srgbClr val=\"\(accent)\"/></a:accent\(index + 1)>"
        }
        colors += "<a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink><a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink>"

        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"6350\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(fill)<a:prstDash val=\"solid\"/></a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        let fonts = "<a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        return OPC.xmlHeader + """
            <a:theme xmlns:a="\(drawingNamespace)" name="Office Theme"><a:themeElements>\
            <a:clrScheme name="Office">\(colors)</a:clrScheme>\
            <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/>\(fonts)</a:majorFont>\
            <a:minorFont><a:latin typeface="Calibri"/>\(fonts)</a:minorFont></a:fontScheme>\
            <a:fmtScheme name="Office"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst>\
            <a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>\
            <a:effectStyleLst>\(effect)\(effect)\(effect)</a:effectStyleLst>\
            <a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme>\
            </a:themeElements></a:theme>
            """
    }()

    /// The master scales its placeholders to the slide, which only differs from 16:9 in
    /// decks of full-bleed images, where no placeholder is used.
    static func master(_ size: PPTXDeck.SlideSize) -> String {
        let scaleX = Double(size.width) / Double(PPTXDeck.widescreen.width)
        let scaleY = Double(size.height) / Double(PPTXDeck.widescreen.height)
        func frame(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> String {
            let scaled = [Double(x) * scaleX, Double(y) * scaleY, Double(width) * scaleX, Double(height) * scaleY].map { Int($0.rounded()) }
            return "<a:xfrm><a:off x=\"\(scaled[0])\" y=\"\(scaled[1])\"/><a:ext cx=\"\(scaled[2])\" cy=\"\(scaled[3])\"/></a:xfrm>"
        }
        let title = """
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
            <p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
            <p:spPr>\(frame(838_200, 365_125, 10_515_600, 1_325_563))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            <p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0" anchor="ctr"><a:normAutofit/></a:bodyPr>\
            <a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Click to edit Master title style</a:t></a:r></a:p></p:txBody></p:sp>
            """
        let body = """
            <p:sp><p:nvSpPr><p:cNvPr id="3" name="Text Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
            <p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>\
            <p:spPr>\(frame(838_200, 1_825_625, 10_515_600, 4_351_338))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            <p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0"><a:normAutofit/></a:bodyPr>\
            <a:lstStyle/><a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Click to edit Master text styles</a:t></a:r></a:p></p:txBody></p:sp>
            """
        var bodyLevels = ""
        for level in 1...9 {
            let size = max(1200, 2000 - (level - 1) * 200)
            let margin = level * 342_900
            bodyLevels += """
                <a:lvl\(level)pPr marL="\(margin)" indent="-342900" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">\
                <a:lnSpc><a:spcPct val="100000"/></a:lnSpc><a:spcBef><a:spcPts val="1000"/></a:spcBef>\
                <a:buFont typeface="Arial"/><a:buChar char="&#8226;"/>\
                <a:defRPr sz="\(size)" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
                <a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl\(level)pPr>
                """
        }
        var otherLevels = ""
        for level in 1...9 {
            otherLevels += """
                <a:lvl\(level)pPr marL="\((level - 1) * 457_200)" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">\
                <a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
                <a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl\(level)pPr>
                """
        }
        return OPC.xmlHeader + """
            <p:sldMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\
            <p:spTree>\(groupHeader)\(title)\(body)</p:spTree></p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
            accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/><p:sldLayoutId id="2147483650" r:id="rId2"/></p:sldLayoutIdLst>\
            <p:txStyles><p:titleStyle><a:lvl1pPr algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">\
            <a:lnSpc><a:spcPct val="90000"/></a:lnSpc><a:spcBef><a:spcPct val="0"/></a:spcBef><a:buNone/>\
            <a:defRPr sz="4000" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
            <a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle>\
            <p:bodyStyle>\(bodyLevels)</p:bodyStyle><p:otherStyle>\(otherLevels)</p:otherStyle></p:txStyles></p:sldMaster>
            """
    }

    static let titleAndContentLayout = OPC.xmlHeader + """
        <p:sldLayout \(namespaces) type="obj" preserve="1"><p:cSld name="Title and Content"><p:spTree>\(groupHeader)\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/>\
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Click to edit Master title style</a:t></a:r></a:p></p:txBody></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Content Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr/>\
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Click to edit Master text styles</a:t></a:r></a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """

    static let blankLayout = OPC.xmlHeader + """
        <p:sldLayout \(namespaces) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(groupHeader)</p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
}
