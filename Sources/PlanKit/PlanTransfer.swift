import Foundation
import Compression

/// Encodes plans and results for sharing without a server:
/// - `.fightplan` / `.fightresult` files (readable JSON) for AirDrop, Messages, WhatsApp, Files
/// - `fight://plan?d=…` links (zlib + base64url) that also fit in a QR code
enum PlanTransfer {
    static let planExtension = "fightplan"
    static let resultExtension = "fightresult"
    static let planTypeIdentifier = "com.shon.fight.plan"
    static let resultTypeIdentifier = "com.shon.fight.result"
    static let urlScheme = "fight"
    /// QR version 40 (error correction M) holds ~2,300 characters; stay under it.
    static let maxQRCharacters = 2200
    /// A real plan is a few KB of JSON. Anything bigger is refused before or while it is
    /// unpacked, so a tiny link can't expand into gigabytes (a "zip bomb") and exhaust memory.
    static let maxPlanBytes = 1_000_000
    /// Longest `fight://` link we try to read (links in messages can exceed QR size).
    static let maxLinkCharacters = 300_000

    enum TransferError: LocalizedError {
        case unreadable, newerVersion(Int), notAPlan

        var errorDescription: String? {
            switch self {
            case .unreadable: return "This file or link isn't a readable FIGHT plan."
            case .newerVersion(let v): return "This plan was made with a newer version of FIGHT (format \(v)). Update the app to open it."
            case .notAPlan: return "This link doesn't contain a FIGHT plan."
            }
        }
    }

    // MARK: JSON

    static func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func data(for plan: TrainingPlan, pretty: Bool = true) throws -> Data {
        try encoder(pretty: pretty).encode(plan)
    }

    static func plan(from data: Data) throws -> TrainingPlan {
        guard data.count <= maxPlanBytes else { throw TransferError.unreadable }
        guard let plan = try? decoder.decode(TrainingPlan.self, from: data), !plan.blocks.isEmpty else {
            throw TransferError.unreadable
        }
        if plan.schemaVersion > TrainingPlan.currentSchemaVersion + 5 {
            throw TransferError.newerVersion(plan.schemaVersion)
        }
        return plan
    }

    static func data(for result: SessionResultPackage) throws -> Data {
        try encoder(pretty: true).encode(result)
    }

    static func result(from data: Data) throws -> SessionResultPackage {
        guard data.count <= maxPlanBytes * 5 else { throw TransferError.unreadable }
        guard let r = try? decoder.decode(SessionResultPackage.self, from: data) else { throw TransferError.unreadable }
        return r
    }

    // MARK: Files

    static func safeFileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(title.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        return cleaned.isEmpty ? "FIGHT-Plan" : String(cleaned.prefix(60))
    }

    /// Writes a shareable `.fightplan` file to the temporary directory.
    static func writePlanFile(_ plan: TrainingPlan) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeFileName(plan.title))
            .appendingPathExtension(planExtension)
        try data(for: plan).write(to: url, options: .atomic)
        return url
    }

    static func writeResultFile(_ result: SessionResultPackage) throws -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeFileName(result.athleteName))_\(safeFileName(result.planTitle))_\(stamp.string(from: result.date))")
            .appendingPathExtension(resultExtension)
        try data(for: result).write(to: url, options: .atomic)
        return url
    }

    // MARK: Links & QR

    /// `fight://plan?d=<zlib+base64url JSON>`
    static func link(for plan: TrainingPlan) throws -> URL {
        let raw = try data(for: plan, pretty: false)
        let compressed = (try? (raw as NSData).compressed(using: .zlib) as Data) ?? raw
        var comps = URLComponents()
        comps.scheme = urlScheme
        comps.host = "plan"
        comps.queryItems = [URLQueryItem(name: "d", value: base64url(compressed))]
        guard let url = comps.url else { throw TransferError.unreadable }
        return url
    }

    static func fitsInQRCode(_ url: URL) -> Bool {
        url.absoluteString.count <= maxQRCharacters
    }

    static func plan(fromLink url: URL) throws -> TrainingPlan {
        guard url.absoluteString.count <= maxLinkCharacters,
              url.scheme?.lowercased() == urlScheme, url.host?.lowercased() == "plan",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value,
              let packed = fromBase64url(value) else {
            throw TransferError.notAPlan
        }
        let raw: Data
        switch inflate(packed, limit: maxPlanBytes) {
        case .ok(let d): raw = d
        case .tooLarge: throw TransferError.unreadable
        case .notCompressed: raw = packed   // older uncompressed links
        }
        return try plan(from: raw)
    }

    enum InflateResult { case ok(Data), tooLarge, notCompressed }

    /// Raw-deflate decompression (the format `NSData.compressed(using: .zlib)` writes)
    /// that stops as soon as the output passes `limit` bytes.
    static func inflate(_ input: Data, limit: Int) -> InflateResult {
        guard !input.isEmpty else { return .notCompressed }
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return .notCompressed
        }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> InflateResult in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return .notCompressed }
            stream.src_ptr = base
            stream.src_size = input.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let srcBefore = stream.src_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                output.append(dst, count: produced)
                if output.count > limit { return .tooLarge }
                switch status {
                case COMPRESSION_STATUS_END:
                    return output.isEmpty ? .notCompressed : .ok(output)
                case COMPRESSION_STATUS_OK:
                    // No input consumed and no output produced: the stream is stuck or truncated.
                    if produced == 0 && stream.src_size == srcBefore { return .notCompressed }
                default:
                    return .notCompressed
                }
            }
        }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
