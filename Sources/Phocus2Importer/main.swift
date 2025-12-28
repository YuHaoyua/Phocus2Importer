// The Swift Programming Language
// https://docs.swift.org/swift-book


import Foundation
import RealmSwift
import CoreGraphics
import ImageIO
import CoreServices

// =======================================================
// App Container Paths (auto-detect; avoid hardcoding username/UUID)
// =======================================================
let phocusBundleID = "com.hasselblad.mobile2"

/// Find container root by scanning ~/Library/Containers/*/Data/Library/Preferences for files containing bundleID.
/// If multiple matches, prefer the one that already contains Data/Library/RealmDB/Album.realm.
func findContainerRoot(bundleID: String) -> URL {
    let fm = FileManager.default
    let containersURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers", isDirectory: true)
    guard fm.fileExists(atPath: containersURL.path) else {
        die("找不到目录：\(containersURL.path)")
    }

    let dirs = (try? fm.contentsOfDirectory(at: containersURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    var candidates: [URL] = []

    for dir in dirs {
        let pref = dir.appendingPathComponent("Data/Library/Preferences", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: pref.path, isDirectory: &isDir), isDir.boolValue else { continue }

        let items = (try? fm.contentsOfDirectory(atPath: pref.path)) ?? []
        if items.contains(where: { $0.contains(bundleID) }) {
            candidates.append(dir)
        }
    }

    guard !candidates.isEmpty else {
        die("未在 ~/Library/Containers 下找到包含 bundleID=\(bundleID) 的容器（Preferences 里未命中）。请先打开一次 App 或检查路径。")
    }

    // Prefer container that already has the expected Realm
    for c in candidates {
        let realm = c.appendingPathComponent("Data/Library/RealmDB/Album.realm")
        if fm.fileExists(atPath: realm.path) {
            return c
        }
    }

    if candidates.count > 1 {
        print("⚠️ 检测到多个容器匹配 bundleID=\(bundleID)，但未找到包含 Album.realm 的那一个，将使用第一个：")
        for c in candidates {
            print("   - \(c.path)")
        }
    }
    return candidates[0]
}

let containerRootURL: URL = findContainerRoot(bundleID: phocusBundleID)
let containerUUID = containerRootURL.lastPathComponent
let containerRootPath = containerRootURL.path

let previewCacheDir = containerRootURL.appendingPathComponent("Data/Library/PreviewCache").path
let imagesDir = containerRootURL.appendingPathComponent("Data/Documents/Images").path
let defaultRealmPath = containerRootURL.appendingPathComponent("Data/Library/RealmDB/Album.realm").path



var exifBinPath: String? = nil

let realmPath = defaultRealmPath
// Input 3FR path (required; usually provided via --3fr)
var src3frPath: String = ""

// If you want to specify timestamp (otherwise use current time)
var importUnixTimestampOverride: Int? = nil
// =======================================================

// ----------------- Realm Model -----------------
class PSLocalPhotoIndexEntity: Object {
    @objc dynamic var hb_imageID: String = ""
    @objc dynamic var hb_deviceName: String? = nil
    @objc dynamic var hb_imageName: String = ""
    @objc dynamic var hb_thumbnailJpeg: String? = nil
    @objc dynamic var hb_mediaType: Int = 0
    @objc dynamic var hb_middleJpeg: String? = nil
    @objc dynamic var hb_fullJpeg: String? = nil
    @objc dynamic var hb_rawFile: String? = nil
    @objc dynamic var hb_heifFile: String? = nil
    @objc dynamic var hb_shot: String? = nil
    @objc dynamic var hb_dateTimeDigitizedStr: String? = nil
    @objc dynamic var hb_dateTimeOriginalStr: String = ""
    @objc dynamic var hb_dateTimeOriginalDesc: String = ""
    @objc dynamic var hb_exifData: Data = Data()
    @objc dynamic var hb_dateTimeDigitized: Date? = nil
    @objc dynamic var hb_dateTimeOriginal: Date = Date()
    @objc dynamic var hb_relyRawFile: String? = nil
    @objc dynamic var hb_adjustmentData: Data? = nil
    @objc dynamic var hb_isAdjusted: Bool = false
    @objc dynamic var hb_isLike: Bool = false
    @objc dynamic var hb_isAIDeNoised: Bool = false
    @objc dynamic var hb_aiDenoiseType: Int = 0
    @objc dynamic var hb_colorMark: String? = nil
    @objc dynamic var hb_storageType: Int = 1
    @objc dynamic var hb_localIdentify: String? = nil
    @objc dynamic var hb_cameraIndexUUID: String? = nil
    @objc dynamic var hb_cameraSerialNumber: String? = nil
    @objc dynamic var hb_rating: Int = 0
    @objc dynamic var hb_dateTimeOffset: String? = nil
    @objc dynamic var hb_dateTimeOriginalLegacy: Date? = nil

    override static func primaryKey() -> String? { "hb_imageID" }
}

// ----------------- EXIF JSON (顺序固定) -----------------
struct ExifDataJSON: Codable {
    let Shot: String
    let Device: String
    let Dimensions: String
    let DateTimeOriginal: String
    let ApertureValue: String
    let OffsetTimeOriginal: String
    let Rating: String
    let ShutterSpeedValue: String
    let ISO: String
    let Orientation: String
}

// ----------------- Utils -----------------
func die(_ msg: String) -> Never { print("❌ \(msg)"); exit(1) }


func formatExposure(_ seconds: Double) -> String {
    if seconds >= 1.0 {
        let v = (seconds * 10).rounded() / 10
        let s = (v.truncatingRemainder(dividingBy: 1) == 0) ? String(Int(v)) : String(v)
        return "\(s)s"
    } else if seconds > 0 {
        let denom = Int((1.0 / seconds).rounded())
        return "1/\(denom)s"
    } else {
        return "0s"
    }
}

func orientationToDegreesString(_ exifOrientation: Int?) -> String {
    guard let o = exifOrientation else { return "0" }
    switch o {
    case 1: return "0"
    case 3: return "180"
    case 6: return "90"
    case 8: return "270"
    default: return "0"
    }
}

// 按你的示例：DateTimeOriginal = "YYYY:MM:DD HH:MM:SS"
// 同时 hb_dateTimeOriginal 你示例表现更像“把这个字符串当 UTC 存进去”（不做 +08 换算）
func parseDateTimeOriginalAsUTC(_ s: String) -> Date? {
    guard !s.isEmpty else { return nil }
    let df = DateFormatter()
    df.dateFormat = "yyyy:MM:dd HH:mm:ss"
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(secondsFromGMT: 0) // 关键：按 UTC 解释，得到 2025-12-07T13:55:50Z 这种
    return df.date(from: s)
}

func dateOnlyDesc(_ s: String) -> String {
    // "YYYY:MM:DD HH:MM:SS" -> "YYYY:MM:DD"
    if s.count >= 10 { return String(s.prefix(10)) }
    return s
}

// 从 3FR 读取所需 exif：优先用系统框架 ImageIO；必要时回退到 exiftool
func extractExifViaImageIO(from3FR path: String) throws -> (exifJSON: ExifDataJSON, deviceName: String, dateTimeOriginalStr: String, offset: String) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        die("3FR 不存在：\(url.path)")
    }

    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw NSError(domain: "ImageIO", code: -1, userInfo: [NSLocalizedDescriptionKey: "CGImageSourceCreateWithURL 失败（可能系统不支持该 RAW）"])
    }

    guard let propsAny = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) else {
        throw NSError(domain: "ImageIO", code: -2, userInfo: [NSLocalizedDescriptionKey: "CGImageSourceCopyPropertiesAtIndex 失败"])
    }

    let props = propsAny as NSDictionary

    // 尺寸
    let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
    let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    let dims = (w != nil && h != nil) ? "\(w!) * \(h!)" : ""

    // Orientation（ImageIO 用 1..8）
    let orient = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    let orientStr = orientationToDegreesString(orient)

    // TIFF: Model
    var device = ""
    if let tiff = props[kCGImagePropertyTIFFDictionary] as? NSDictionary {
        device = (tiff[kCGImagePropertyTIFFModel] as? String) ?? ""
    }

    // EXIF
    var dto = ""
    var offset = ""
    var fnum: Double? = nil
    var apv: Double? = nil
    var exposureSeconds: Double? = nil
    var apexShutter: Double? = nil
    var isoVal: Int? = nil
    var lensModel: String = ""

    if let exif = props[kCGImagePropertyExifDictionary] as? NSDictionary {
        dto = (exif[kCGImagePropertyExifDateTimeOriginal] as? String) ?? ""
        // OffsetTimeOriginal 不是所有 RAW 都有；若有一般是 "+08:00" 这种
        if let k = kCGImagePropertyExifOffsetTimeOriginal as CFString? {
            offset = (exif[k] as? String) ?? ""
        }

        if let n = exif[kCGImagePropertyExifFNumber] as? NSNumber { fnum = n.doubleValue }
        if let n = exif[kCGImagePropertyExifApertureValue] as? NSNumber { apv = n.doubleValue }

        if let n = exif[kCGImagePropertyExifExposureTime] as? NSNumber { exposureSeconds = n.doubleValue }
        if let n = exif[kCGImagePropertyExifShutterSpeedValue] as? NSNumber { apexShutter = n.doubleValue }

        // ISO 通常是数组
        if let arr = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = arr.first {
            isoVal = first.intValue
        } else if let n = exif[kCGImagePropertyExifISOSpeedRatings] as? NSNumber {
            isoVal = n.intValue
        }

        // LensModel（有些机型会在 Exif 字典里）
        if let k = kCGImagePropertyExifLensModel as CFString? {
            lensModel = (exif[k] as? String) ?? ""
        }
    }

    // ExifAux 里也可能有 LensModel / Serial 等
    if lensModel.isEmpty, let aux = props[kCGImagePropertyExifAuxDictionary] as? NSDictionary {
        if let k = kCGImagePropertyExifAuxLensModel as CFString? {
            lensModel = (aux[k] as? String) ?? ""
        }
    }

    // Rating（不一定有；尽量从 IPTC/XMP 里找；找不到则按 Optional(0)）
    var ratingNum: Int? = nil
    if let iptc = props[kCGImagePropertyIPTCDictionary] as? NSDictionary {
        if let k = kCGImagePropertyIPTCStarRating as CFString? {
            ratingNum = (iptc[k] as? NSNumber)?.intValue
        }
    }
    // XMP（有些 SDK 没有暴露 kCGImagePropertyXMPDictionary 常量；用字面量 "XMP" 兼容）
    let xmpKey = "XMP" as CFString
    if ratingNum == nil, let xmp = props[xmpKey] as? NSDictionary {
        // 有的文件是 "Rating" 或 "xmp:Rating"，这里做宽松匹配
        if let n = xmp["Rating"] as? NSNumber { ratingNum = n.intValue }
        if ratingNum == nil, let n = xmp["xmp:Rating"] as? NSNumber { ratingNum = n.intValue }
    }

    let shot = lensModel

    let apertureStr: String = {
        if let f = fnum {
            let v = (f * 10).rounded() / 10
            return (v.truncatingRemainder(dividingBy: 1) == 0) ? String(Int(v)) : String(v)
        } else if let a = apv {
            let v = (a * 10).rounded() / 10
            return (v.truncatingRemainder(dividingBy: 1) == 0) ? String(Int(v)) : String(v)
        }
        return ""
    }()

    if exposureSeconds == nil, let apex = apexShutter {
        // APEX ShutterSpeedValue -> seconds
        exposureSeconds = pow(2.0, -apex)
    }
    let shutterStr = exposureSeconds != nil ? formatExposure(exposureSeconds!) : ""

    let isoStr = isoVal != nil ? "\(isoVal!)" : ""

    // 你希望是 "Optional(0)" 这种格式
    let ratingStr = "Optional(\(ratingNum ?? 0))"

    let exifJSON = ExifDataJSON(
        Shot: shot,
        Device: device,
        Dimensions: dims,
        DateTimeOriginal: dto,
        ApertureValue: apertureStr,
        OffsetTimeOriginal: offset,
        Rating: ratingStr,
        ShutterSpeedValue: shutterStr,
        ISO: isoStr,
        Orientation: orientStr
    )

    return (exifJSON, device, dto, offset)
}

// 统一入口：仅使用系统框架 ImageIO
func extractExif(from3FR path: String) throws -> (exifJSON: ExifDataJSON, deviceName: String, dateTimeOriginalStr: String, offset: String) {
    let r = try extractExifViaImageIO(from3FR: path)
    print("✅ EXIF: 使用系统框架 ImageIO 读取")
    return r
}

func writeBlackJPEG(to url: URL, width: Int, height: Int, quality: Double = 0.92) throws {
    precondition(width > 0 && height > 0)

    // RGBA 8-bit
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var data = Data(count: bytesPerRow * height)

    // 填充黑色 + 不透明 alpha=255
    data.withUnsafeMutableBytes { raw in
        guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        let n = width * height
        for i in 0..<n {
            let o = i * 4
            p[o + 0] = 0   // R
            p[o + 1] = 0   // G
            p[o + 2] = 0   // B
            p[o + 3] = 255 // A
        }
    }

    let cs = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let provider = CGDataProvider(data: data as CFData) else {
        throw NSError(domain: "Img", code: -1, userInfo: [NSLocalizedDescriptionKey: "CGDataProvider 创建失败"])
    }
    guard let cg = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: cs,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw NSError(domain: "Img", code: -2, userInfo: [NSLocalizedDescriptionKey: "CGImage 创建失败"])
    }

    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, kUTTypeJPEG, 1, nil) else {
        throw NSError(domain: "Img", code: -3, userInfo: [NSLocalizedDescriptionKey: "CGImageDestination 创建失败"])
    }

    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: max(0.0, min(1.0, quality))
    ]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)

    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "Img", code: -4, userInfo: [NSLocalizedDescriptionKey: "JPEG 写入失败"])
    }
}

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func copyReplace(_ src: String, _ dst: String) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
    try fm.copyItem(atPath: src, toPath: dst)
}

/// Patch the destination file in-place: scan only the first `maxScanBytes` bytes, replace only the first occurrence.
/// Returns (patched, offset).
func patchFirst4KBInPlace(filePath: String,
                          search: [UInt8],
                          replace: [UInt8],
                          maxScanBytes: Int = 4096) throws -> (Bool, Int?) {
    guard search.count == replace.count, !search.isEmpty else {
        return (false, nil)
    }

    let url = URL(fileURLWithPath: filePath)
    let fh = try FileHandle(forUpdating: url)
    defer { try? fh.close() }

    let headData = try fh.read(upToCount: maxScanBytes) ?? Data()
    if headData.isEmpty { return (false, nil) }

    var buf = [UInt8](headData)

    // naive first-match search
    if buf.count >= search.count {
        for i in 0...(buf.count - search.count) {
            var ok = true
            for j in 0..<search.count {
                if buf[i + j] != search[j] { ok = false; break }
            }
            if ok {
                for j in 0..<replace.count {
                    buf[i + j] = replace[j]
                }
                // write back only the modified header region
                try fh.seek(toOffset: 0)
                try fh.write(contentsOf: Data(buf))
                return (true, i)
            }
        }
    }

    return (false, nil)
}

// ----------------- Args / Help -----------------
func printHelp() {
    let exe = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "Phocus2Importer"
    print("""
\(exe) - Import Hasselblad .3FR into Phocus 2 (macOS) by writing files + Album.realm

USAGE:
  1) 单文件导入:
     \(exe) --3fr /path/to/XXXX.3FR [--exifbin /path/to/exif.bin] [--ts <unix_seconds>]

  2) 目录批量导入:
     \(exe) /path/to/folder

OPTIONS:
  --3fr <file>        指定单个 .3FR 文件导入
  --exifbin <file>    （可选）手动指定 hb_exifData 的 bin（需为 ExifDataJSON 的 JSON 编码）
  --ts <int>          （可选）指定导入 timestamp（默认当前时间秒）
  -h, --help          显示帮助

""")
}

// Parsing
let args = CommandLine.arguments
var batchDirPath: String? = nil
var i = 1
while i < args.count {
    let a = args[i]
    if a == "--help" || a == "-h" {
        printHelp()
        exit(0)
    } else if a == "--3fr" {
        guard i + 1 < args.count else { die("--3fr 需要一个文件路径参数") }
        src3frPath = args[i + 1]
        i += 2
        continue
    } else if a == "--exifbin" {
        guard i + 1 < args.count else { die("--exifbin 需要一个文件路径参数") }
        exifBinPath = args[i + 1]
        i += 2
        continue
    } else if a == "--ts" {
        guard i + 1 < args.count else { die("--ts 需要一个整数参数") }
        if let n = Int(args[i + 1]) {
            importUnixTimestampOverride = n
        } else {
            die("--ts 参数必须是整数：\(args[i + 1])")
        }
        i += 2
        continue
    } else if a.hasPrefix("-") {
        die("未知参数：\(a)（用 --help 查看用法）")
    } else {
        // positional path => batch mode directory (only one allowed)
        if batchDirPath == nil {
            batchDirPath = a
        } else {
            die("批量导入模式只允许一个目录路径参数（用 --help 查看用法）")
        }
        i += 1
        continue
    }
}

// If user provided only a positional file path, treat it as --3fr (convenience)
if src3frPath.isEmpty, let p = batchDirPath {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue {
        // file
        src3frPath = p
        batchDirPath = nil
    }
}

// Enforce: batch mode doesn't allow any custom flags
if let _ = batchDirPath {
    if !src3frPath.isEmpty || exifBinPath != nil || importUnixTimestampOverride != nil {
        die("批量导入模式不支持任何自定义参数；请仅使用：Phocus2Importer /path/to/folder")
    }
}

// ----------------- Main -----------------
do {
    // Always use auto-detected container paths + defaultRealmPath
    guard FileManager.default.fileExists(atPath: realmPath) else { die("Realm 不存在：\(realmPath)") }

    print("🔎 Phocus BundleID=\(phocusBundleID)")
    print("🔎 ContainerUUID=\(containerUUID)")
    print("🔎 ContainerRoot=\(containerRootPath)")

    // Prepare Realm (open once)
    var config = Realm.Configuration(fileURL: URL(fileURLWithPath: realmPath))
    config.schemaVersion = 13
    config.objectTypes = [PSLocalPhotoIndexEntity.self]
    let realm = try Realm(configuration: config)

    // Ensure output dirs exist (fixed to container paths)
    ensureDir(previewCacheDir)
    ensureDir(imagesDir)

    // Helper: import one 3FR
    func importOne3FR(_ filePath: String, tsOverride: Int?, strictDuplicate: Bool) throws -> Bool {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("⚠️ 跳过：文件不存在：\(filePath)")
            return false
        }
        let srcURL = URL(fileURLWithPath: filePath)
        let ext = srcURL.pathExtension.lowercased()
        guard ext == "3fr" else {
            print("⚠️ 跳过：不是 .3FR：\(filePath)")
            return false
        }

        let baseName = srcURL.deletingPathExtension().lastPathComponent
        if baseName.isEmpty {
            print("⚠️ 跳过：无法解析文件名：\(filePath)")
            return false
        }

        // timestamp (ensure unique)
        let ts = tsOverride ?? Int(Date().timeIntervalSince1970)
        let hbImageID = "\(baseName)3FR\(ts)"

        // Duplicate check
        if realm.object(ofType: PSLocalPhotoIndexEntity.self, forPrimaryKey: hbImageID) != nil {
            if strictDuplicate {
                die("主键已存在：\(hbImageID)（你可能重复导入了同一个 ts）")
            } else {
                print("⚠️ 跳过：主键已存在：\(hbImageID)")
                return false
            }
        }

        let rawDstName = "\(hbImageID).3FR"
        let thumbDstName = "Thumbnail_\(hbImageID).jpg"
        let middleDstName = "Middle_\(hbImageID).jpg"

        // EXIF（两种模式：自动从 3FR 读取 / 手动指定 exif bin）
        let exifData: Data
        let deviceName: String
        let dateTimeOriginalStr: String
        let offset: String

        if let exifBinPath = exifBinPath {
            guard FileManager.default.fileExists(atPath: exifBinPath) else {
                die("exif bin 不存在：\(exifBinPath)")
            }
            exifData = try Data(contentsOf: URL(fileURLWithPath: exifBinPath))

            if let decoded = try? JSONDecoder().decode(ExifDataJSON.self, from: exifData) {
                deviceName = decoded.Device
                dateTimeOriginalStr = decoded.DateTimeOriginal
                offset = decoded.OffsetTimeOriginal
            } else {
                deviceName = ""
                dateTimeOriginalStr = ""
                offset = ""
                print("⚠️ 提供的 exif bin 无法解码为 ExifDataJSON，将仅写入 hb_exifData，其它 exif 相关字段将为空")
            }
        } else {
            let (exif, dev, dto, off) = try extractExif(from3FR: filePath)
            let enc = JSONEncoder()
            exifData = try enc.encode(exif)
            deviceName = dev
            dateTimeOriginalStr = dto
            offset = off
        }

        let dtOriginal = parseDateTimeOriginalAsUTC(dateTimeOriginalStr) ?? Date()
        let dtDesc = dateOnlyDesc(dateTimeOriginalStr)

        // 4) adjustmentData：始终写入 0 字节（不再支持外部输入）
        let adjData = Data() // 0 bytes
        print("🧩 hb_adjustmentData bytes = \(adjData.count) (always-empty)")

        // Write RAW to container
        let rawDstPath = (imagesDir as NSString).appendingPathComponent(rawDstName)
        try copyReplace(filePath, rawDstPath)

        // Patch header (scan only first 4KB, replace only first match)
        let searchBytes: [UInt8]  = [0x12, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]
        let replaceBytes: [UInt8] = [0x12, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00]
        do {
            let (patched, off) = try patchFirst4KBInPlace(filePath: rawDstPath,
                                                         search: searchBytes,
                                                         replace: replaceBytes,
                                                         maxScanBytes: 4096)
            if patched {
                print("🧩 RAW 头部已替换 1 处（offset=\(off ?? -1)），40->42")
            }
        } catch {
            print("⚠️ RAW 头部替换失败：\(error)")
        }

        // Write preview JPEGs (black)
        let thumbDstPath = (previewCacheDir as NSString).appendingPathComponent(thumbDstName)
        let middleDstPath = (previewCacheDir as NSString).appendingPathComponent(middleDstName)
        try writeBlackJPEG(to: URL(fileURLWithPath: thumbDstPath), width: 400, height: 300)
        try writeBlackJPEG(to: URL(fileURLWithPath: middleDstPath), width: 1378, height: 1033)

        // hb_cameraIndexUUID：按你给的“前 8 位文件名 + 固定后缀”
        let prefix8 = String(baseName.prefix(8))
        let cameraIndexUUIDSuffix = "f9617ffbebb1cb5b434bf12a4628f081927HASBL"
        let cameraIndexUUID = prefix8 + cameraIndexUUIDSuffix

        // Build Realm object
        let obj = PSLocalPhotoIndexEntity()
        obj.hb_imageID = hbImageID
        obj.hb_deviceName = deviceName.isEmpty ? nil : deviceName
        obj.hb_imageName = baseName
        obj.hb_thumbnailJpeg = thumbDstName
        obj.hb_mediaType = 0
        obj.hb_middleJpeg = middleDstName
        obj.hb_fullJpeg = nil
        obj.hb_rawFile = rawDstName
        obj.hb_heifFile = nil
        obj.hb_shot = nil
        obj.hb_dateTimeDigitizedStr = nil
        obj.hb_dateTimeOriginalStr = dateTimeOriginalStr
        obj.hb_dateTimeOriginalDesc = dtDesc
        obj.hb_exifData = exifData
        obj.hb_dateTimeDigitized = nil
        obj.hb_dateTimeOriginal = dtOriginal
        obj.hb_relyRawFile = nil
        obj.hb_adjustmentData = adjData // 0 bytes
        obj.hb_isAdjusted = false
        obj.hb_isLike = false
        obj.hb_isAIDeNoised = false
        obj.hb_aiDenoiseType = 0
        obj.hb_colorMark = "0"
        obj.hb_storageType = 1
        obj.hb_localIdentify = nil
        obj.hb_cameraIndexUUID = cameraIndexUUID
        obj.hb_cameraSerialNumber = nil
        obj.hb_rating = 0
        obj.hb_dateTimeOffset = offset.isEmpty ? nil : offset
        obj.hb_dateTimeOriginalLegacy = nil

        try realm.write {
            realm.add(obj)
        }

        print("🎉 导入成功：\(srcURL.lastPathComponent) -> hb_imageID=\(hbImageID)")
        return true
    }

    // Mode selection
    if !src3frPath.isEmpty {
        // Single-file (old mode)
        try importOne3FR(src3frPath, tsOverride: importUnixTimestampOverride, strictDuplicate: true)
        print("📁 RAW 目录：\(imagesDir)")
        print("📁 PreviewCache：\(previewCacheDir)")
        print("📁 Realm：\(realmPath)")

    } else if let dir = batchDirPath {
        // Batch folder import (new mode, no custom args)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            die("批量导入模式需要一个目录路径：\(dir)")
        }

        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let threeFRs = items.filter { $0.pathExtension.lowercased() == "3fr" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if threeFRs.isEmpty {
            die("目录中未发现 .3FR：\(dir)")
        }

        print("🚀 批量导入：目录=\(dir)  文件数=\(threeFRs.count)")

        let baseTs = Int(Date().timeIntervalSince1970)
        var okCount = 0
        var failCount = 0

        for (idx, f) in threeFRs.enumerated() {
            // Ensure unique timestamp per file to avoid hb_imageID collision
            let ts = baseTs + idx
            do {
                let ok = try importOne3FR(f.path, tsOverride: ts, strictDuplicate: false)
                if ok { okCount += 1 } else { failCount += 1 }
            } catch {
                failCount += 1
                print("❌ 导入失败：\(f.lastPathComponent)：\(error)")
            }
        }

        print("✅ 批量导入完成：成功=\(okCount)  失败/跳过=\(failCount)")
        print("📁 RAW 目录：\(imagesDir)")
        print("📁 PreviewCache：\(previewCacheDir)")
        print("📁 Realm：\(realmPath)")

    } else {
        // No args
        printHelp()
        exit(1)
    }

} catch {
    die("异常：\(error)")
}