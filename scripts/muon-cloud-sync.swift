#!/usr/bin/env swift
//
//  muon-cloud-sync — normalise local FLACs to 16-bit and mirror them to pCloud.
//
//  Two jobs, in this order:
//
//  1. Any FLAC that is not 16-bit (or is above 48 kHz) is re-encoded in place to
//     16-bit, halving the rate within its own family (96k → 48k, 88.2k → 44.1k).
//     Tags and embedded cover art are carried over; the original is only replaced
//     once the new file has been re-read and checked.
//
//  2. Every FLAC that is not already on the remote is uploaded, mirroring its
//     path under the local root.
//
//  Not creating duplicates is the delicate part, because the same album may sit
//  at a different depth on the remote, and because resampling changes the bytes.
//  A file is identified by the MD5 of its *decoded audio*, which FLAC stores in
//  its STREAMINFO header — so a copy can be recognised wherever it lives, and a
//  file we just resampled is uploaded over the object its original occupied
//  rather than beside it.
//
//  Usage:
//    swift scripts/muon-cloud-sync.swift                 # dry run (default)
//    swift scripts/muon-cloud-sync.swift --apply
//    swift scripts/muon-cloud-sync.swift --apply --no-upload    # resample only
//    swift scripts/muon-cloud-sync.swift --refresh-index
//
//  Requires: rclone and ffmpeg. soxr is used when the ffmpeg build has it;
//  otherwise swr with triangular dither, which handles 2:1 decimation well.
//

import Foundation

// Progress must be visible when stdout is a file, not a terminal.
setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Options

struct Options {
    var root = NSHomeDirectory() + "/Music_not_shared"
    var remote = "pcloud:Music"
    var apply = false
    var resample = true
    var upload = true
    var jobs = 8
    var verbose = false
    var refreshIndex = false
    var indexPath = NSTemporaryDirectory() + "muon-cloud-index.json"
    var manifestPath = NSTemporaryDirectory() + "muon-cloud-manifest.tsv"
    var logPath = ""
    /// Anything above this is halved within its own family.
    var maxSampleRate = 48_000
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--apply": o.apply = true
        case "--dry-run": o.apply = false
        case "--no-resample": o.resample = false
        case "--no-upload": o.upload = false
        case "--verbose", "-v": o.verbose = true
        case "--refresh-index": o.refreshIndex = true
        case "--root": o.root = it.next() ?? o.root
        case "--remote": o.remote = it.next() ?? o.remote
        case "--index": o.indexPath = it.next() ?? o.indexPath
        case "--manifest": o.manifestPath = it.next() ?? o.manifestPath
        case "--log": o.logPath = it.next() ?? o.logPath
        case "--jobs": o.jobs = Int(it.next() ?? "") ?? o.jobs
        case "--max-sample-rate": o.maxSampleRate = Int(it.next() ?? "") ?? o.maxSampleRate
        case "--help", "-h":
            print("""
            muon-cloud-sync — resample FLACs to 16-bit and mirror them to a remote.

              --dry-run             report only (default)
              --apply               actually re-encode and upload
              --no-resample         skip step 1
              --no-upload           skip step 2
              --root PATH           local root (default ~/Music_not_shared)
              --remote REMOTE:PATH  rclone destination (default pcloud:Music)
              --refresh-index       re-list the remote instead of using the cache
              --index PATH          where the remote listing is cached
              --manifest PATH       write the upload list (size-sorted) here
              --log PATH            rclone transfer log (per-file, with progress)
              --jobs N              parallel re-encodes (default 8)
              --max-sample-rate N   rates above this are halved (default 48000)
              --verbose             list every file
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument: \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

// MARK: - Shell

@discardableResult
func run(_ launchPath: String, _ args: [String], captureStdout: Bool = true,
         showErrors: Bool = false) -> (status: Int32, out: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    if captureStdout { p.standardOutput = pipe }
    p.standardError = showErrors ? FileHandle.standardError : FileHandle.nullDevice
    do { try p.run() } catch { return (-1, Data()) }
    var data = Data()
    if captureStdout { data = pipe.fileHandleForReading.readDataToEndOfFile() }
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

func which(_ tool: String) -> String? {
    let (st, out) = run("/usr/bin/env", ["which", tool])
    guard st == 0 else { return nil }
    let s = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

// MARK: - FLAC

/// The fields of a FLAC STREAMINFO block. `audioMD5` is the MD5 of the *decoded*
/// samples, so it identifies the recording independently of how it was encoded —
/// but it changes when the audio itself is resampled.
struct FlacInfo {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let totalSamples: Int64
    let audioMD5: String

    init?(header b: [UInt8]) {
        guard b.count >= 42,
              b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43,  // "fLaC"
              (b[4] & 0x7F) == 0                                        // STREAMINFO first
        else { return nil }
        let s = Array(b[8..<42])
        sampleRate = (Int(s[10]) << 12) | (Int(s[11]) << 4) | (Int(s[12]) >> 4)
        channels = ((Int(s[12]) >> 1) & 0x7) + 1
        bitsPerSample = (((Int(s[12]) & 0x1) << 4) | (Int(s[13]) >> 4)) + 1
        totalSamples = Int64(s[13] & 0x0F) << 32 | Int64(s[14]) << 24
            | Int64(s[15]) << 16 | Int64(s[16]) << 8 | Int64(s[17])
        audioMD5 = s[18...33].map { String(format: "%02x", $0) }.joined()
    }

    init?(path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let d = try? fh.read(upToCount: 42) else { return nil }
        self.init(header: [UInt8](d))
    }

    var duration: Double { sampleRate > 0 ? Double(totalSamples) / Double(sampleRate) : 0 }
    var needsResample: Bool { bitsPerSample != 16 || sampleRate > 48_000 }

    /// FLAC rarely compresses below ~50% of the raw PCM it declares. A file a
    /// twentieth of that size is truncated — a broken download whose header still
    /// promises the full stream. Uploading it, or feeding it to ffmpeg, is worse
    /// than skipping it.
    func looksTruncated(fileSize: Int64) -> Bool {
        let rawBytes = totalSamples * Int64(channels) * Int64(bitsPerSample / 8)
        guard rawBytes > 0 else { return false }
        return Double(fileSize) < Double(rawBytes) * 0.05
    }
}

/// 96k → 48k, 88.2k → 44.1k: stay in the file's own sample-rate family so the
/// conversion is a clean decimation rather than an awkward ratio.
func targetRate(for rate: Int, max: Int) -> Int {
    guard rate > max else { return rate }
    var r = rate
    while r > max, r % 2 == 0 { r /= 2 }
    return r
}

// MARK: - Remote index

struct RemoteFile: Decodable {
    let Path: String
    let Name: String
    let Size: Int64
}

func loadRemoteIndex(_ o: Options) -> [RemoteFile] {
    let fm = FileManager.default
    if !o.refreshIndex, fm.fileExists(atPath: o.indexPath),
       let d = fm.contents(atPath: o.indexPath),
       let files = try? JSONDecoder().decode([RemoteFile].self, from: d) {
        print("remote index: \(files.count) files (cached — pass --refresh-index to re-list)")
        return files
    }
    print("listing \(o.remote) …")
    guard let rclone = which("rclone") else { fatalError("rclone not found") }
    let (st, out) = run(rclone, ["lsjson", "-R", "--files-only", o.remote])
    guard st == 0, let files = try? JSONDecoder().decode([RemoteFile].self, from: out) else {
        FileHandle.standardError.write("rclone listing failed\n".data(using: .utf8)!)
        exit(1)
    }
    try? out.write(to: URL(fileURLWithPath: o.indexPath))
    print("remote index: \(files.count) files")
    return files
}

/// Read a remote FLAC's STREAMINFO without downloading the file.
func remoteFlacInfo(_ remotePath: String, rclone: String) -> FlacInfo? {
    let (st, out) = run(rclone, ["cat", "--count", "42", remotePath])
    guard st == 0 else { return nil }
    return FlacInfo(header: [UInt8](out))
}

// MARK: - Work items

struct LocalFlac {
    let path: String
    let relative: String
    let size: Int64
    let info: FlacInfo
}

enum Plan {
    case skipPresent(remote: String)
    case upload(to: String)
    case resampleThenUpload(to: String, rate: Int)
    case resampleOnly(rate: Int)
    case resampleThenReplace(remote: String, rate: Int)
}

// MARK: - Main

let o = parseOptions()
guard let rclone = which("rclone") else { fatalError("rclone not found in PATH") }
guard let ffmpeg = which("ffmpeg") else { fatalError("ffmpeg not found in PATH") }

/// soxr is the better resampler, but Homebrew's ffmpeg is not built with it.
/// Without it, fall back to ffmpeg's own swr — a 2:1 decimation it handles well —
/// with an explicit filter and, crucially, dither: reducing 24-bit to 16-bit by
/// plain truncation would add quantisation distortion.
let hasSoxr: Bool = {
    let (st, out) = run(ffmpeg, ["-hide_banner", "-buildconf"])
    return st == 0 && String(decoding: out, as: UTF8.self).contains("libsoxr")
}()

func audioFilter(rate: Int) -> String {
    hasSoxr
        ? "aresample=resampler=soxr:precision=28:out_sample_fmt=s16:out_sample_rate=\(rate):dither_method=triangular_hp"
        : "aresample=out_sample_fmt=s16:out_sample_rate=\(rate):filter_size=256:cutoff=0.95:dither_method=triangular_hp"
}

// The directory enumerator yields canonical paths (/private/var/…), so the root
// must be canonical too — otherwise every relative path is silently mangled.
// `resolvingSymlinksInPath()` is not the tool for this: it *strips* /private.
let rootURL: URL = {
    let u = URL(fileURLWithPath: o.root).standardizedFileURL
    if let c = try? u.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        return URL(fileURLWithPath: c)
    }
    return u
}()
print(o.apply ? "muon-cloud-sync — APPLYING" : "muon-cloud-sync — dry run (nothing will change)")
print("local root: \(rootURL.path)\nremote:     \(o.remote)")
print("resampler:  \(hasSoxr ? "soxr" : "swr (ffmpeg lacks libsoxr) + triangular_hp dither")\n")

// --- local files
var locals: [LocalFlac] = []
if let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
    for case let f as URL in e {
        guard f.pathExtension.lowercased() == "flac",
              !f.lastPathComponent.hasPrefix("._"),
              (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let info = FlacInfo(path: f.path) else { continue }
        let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard f.path.hasPrefix(rootURL.path + "/") else {
            FileHandle.standardError.write("path outside root, skipping: \(f.path)\n".data(using: .utf8)!)
            continue
        }
        let rel = String(f.path.dropFirst(rootURL.path.count + 1))
        locals.append(LocalFlac(path: f.path, relative: rel, size: size, info: info))
    }
}
locals.sort { $0.relative < $1.relative }

let truncated = locals.filter { $0.info.looksTruncated(fileSize: $0.size) }
locals.removeAll { $0.info.looksTruncated(fileSize: $0.size) }
print("local FLACs: \(locals.count)")
if !truncated.isEmpty {
    print("\nskipping \(truncated.count) truncated file(s) — header promises audio the file does not contain:")
    for t in truncated {
        print(String(format: "  %@ (%lld bytes, header claims %.0fs)", t.relative, t.size, t.info.duration))
    }
}

// --- remote index
let remoteFiles = loadRemoteIndex(o)
var bySizeName: [String: String] = [:]      // "name\u{1}size" -> remote path
var byName: [String: [RemoteFile]] = [:]
for r in remoteFiles where r.Name.lowercased().hasSuffix(".flac") {
    bySizeName["\(r.Name)\u{1}\(r.Size)"] = r.Path
    byName[r.Name, default: []].append(r)
}

/// Where this file already lives on the remote, if anywhere. Cheap identity
/// first (same name and byte size); otherwise compare the decoded-audio MD5
/// against same-named remote objects, which finds a copy filed under any path.
func findRemote(_ f: LocalFlac) -> String? {
    if let p = bySizeName["\((f.path as NSString).lastPathComponent)\u{1}\(f.size)"] { return p }
    let name = (f.path as NSString).lastPathComponent
    for cand in byName[name] ?? [] {
        guard let ri = remoteFlacInfo(o.remote + "/" + cand.Path, rclone: rclone) else { continue }
        if ri.audioMD5 == f.info.audioMD5, ri.audioMD5 != String(repeating: "0", count: 32) {
            return cand.Path
        }
    }
    return nil
}

print("resolving what is already on the remote …")
// A cheap name+size hit needs no network; only ambiguous names do, so resolve
// them concurrently rather than paying ~2.5s of rclone round-trip each in turn.
var resolved = [String?](repeating: nil, count: locals.count)
let resolveQueue = OperationQueue()
resolveQueue.maxConcurrentOperationCount = max(4, o.jobs)
let resolveLock = NSLock()
var resolvedCount = 0
for (i, f) in locals.enumerated() {
    guard o.upload || (o.resample && f.info.needsResample) else { continue }
    resolveQueue.addOperation {
        let r = findRemote(f)
        resolveLock.lock()
        resolved[i] = r
        resolvedCount += 1
        if resolvedCount % 500 == 0 { print("  … \(resolvedCount)/\(locals.count)") }
        resolveLock.unlock()
    }
}
resolveQueue.waitUntilAllOperationsAreFinished()

var plans: [(LocalFlac, Plan)] = []
for (i, f) in locals.enumerated() {
    let needs = o.resample && f.info.needsResample
    let rate = targetRate(for: f.info.sampleRate, max: o.maxSampleRate)
    let existing = resolved[i]

    switch (needs, existing) {
    case (false, let r?):        plans.append((f, .skipPresent(remote: r)))
    case (false, nil):           plans.append((f, o.upload ? .upload(to: f.relative) : .skipPresent(remote: "")))
    // Resampled bytes differ from whatever is up there, so overwrite that very
    // object; uploading to the mirrored path instead would leave two copies.
    case (true, let r?):         plans.append((f, o.upload ? .resampleThenReplace(remote: r, rate: rate)
                                                           : .resampleOnly(rate: rate)))
    case (true, nil):            plans.append((f, o.upload ? .resampleThenUpload(to: f.relative, rate: rate)
                                                           : .resampleOnly(rate: rate)))
    }
}

var toResample = 0, toUpload = 0, toReplace = 0, present = 0
var uploadBytes: Int64 = 0, resampleBytes: Int64 = 0
for (f, p) in plans {
    switch p {
    case .skipPresent: present += 1
    case .upload: toUpload += 1; uploadBytes += f.size
    case .resampleOnly: toResample += 1; resampleBytes += f.size
    case .resampleThenUpload: toResample += 1; toUpload += 1; resampleBytes += f.size; uploadBytes += f.size
    case .resampleThenReplace: toResample += 1; toReplace += 1; resampleBytes += f.size
    }
}

func gb(_ b: Int64) -> String { String(format: "%.2f GB", Double(b) / 1e9) }
func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1e6) }

/// The upload list, biggest first, written where the caller can read it.
@discardableResult
func writeManifest(_ items: [(dest: String, size: Int64)], to path: String, remote: String) -> [String] {
    guard !items.isEmpty else { return [] }
    let sorted = items.sorted { $0.size > $1.size }
    let body = sorted.enumerated().map { i, it in
        String(format: "%5d\t%12lld\t%@", i + 1, it.size, it.dest)
    }.joined(separator: "\n")
    let total = sorted.reduce(Int64(0)) { $0 + $1.size }
    let header = "# \(sorted.count) files, \(gb(total)), largest first — destination is under \(remote)\n#\tbytes\tpath\n"
    try? (header + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    return sorted.map(\.dest)
}

print("""

plan
  already on remote          : \(present)
  to re-encode to 16-bit     : \(toResample)  (\(gb(resampleBytes)) before)
  to upload (new path)       : \(toUpload)  (\(gb(uploadBytes)))
  to replace on remote       : \(toReplace)  (resampled copies of objects already there)
""")

// Manifest is useful before anything happens, so write it during the dry run too.
// (Sizes here are pre-re-encode; the apply path rewrites them with real sizes.)
var plannedUploads: [(dest: String, size: Int64)] = []
for (f, p) in plans {
    switch p {
    case .upload(let d), .resampleThenUpload(let d, _): plannedUploads.append((d, f.size))
    default: break
    }
}
if !plannedUploads.isEmpty {
    writeManifest(plannedUploads, to: o.manifestPath, remote: o.remote)
    print("\nupload manifest (largest first): \(o.manifestPath)")
    for (i, it) in plannedUploads.sorted(by: { $0.size > $1.size }).prefix(10).enumerated() {
        print(String(format: "  %2d. %9s  %@", i + 1, (mb(it.size) as NSString).utf8String!, it.dest))
    }
    if plannedUploads.count > 10 { print("  … \(plannedUploads.count - 10) more in the manifest") }
}

if o.verbose || !o.apply {
    for (f, p) in plans {
        switch p {
        case .resampleOnly(let r):
            print("  resample  \(f.info.bitsPerSample)bit/\(f.info.sampleRate) -> 16bit/\(r)  \(f.relative)")
        case .resampleThenUpload(let dest, let r):
            print("  resample+upload  \(f.info.bitsPerSample)bit/\(f.info.sampleRate) -> 16bit/\(r)  -> \(o.remote)/\(dest)")
        case .resampleThenReplace(let rp, let r):
            print("  resample+REPLACE \(f.info.bitsPerSample)bit/\(f.info.sampleRate) -> 16bit/\(r)  -> \(o.remote)/\(rp)")
        case .upload(let dest):
            if o.verbose { print("  upload    \(f.relative) -> \(o.remote)/\(dest)") }
        case .skipPresent:
            if o.verbose { print("  present   \(f.relative)") }
        }
    }
}

guard o.apply else {
    print("\nDry run. Re-run with --apply.")
    exit(0)
}

// MARK: - Step 1: re-encode

/// Re-encode to 16-bit at `rate`, keeping tags and embedded art. The original is
/// replaced only after the result has been re-read and its duration checked, so a
/// failed or truncated encode can never destroy the source.
struct ResampleError: Error { let message: String }

func resample(_ f: LocalFlac, to rate: Int) -> Result<Int64, ResampleError> {
    let tmp = f.path + ".16bit.tmp.flac"
    try? FileManager.default.removeItem(atPath: tmp)
    // -map 0 -c:v copy keeps the embedded cover art, which -vn would drop.
    //
    // ffmpeg round-trips Vorbis comments through its own key names: COMMENT is
    // rewritten as DESCRIPTION and an `encoder` tag is added. The values survive.
    // Restoring the keys with `metaflac --remove-all-tags --import-tags-from` is
    // NOT an option: its tag export cannot round-trip multiline fields such as
    // UNSYNCEDLYRICS, and it removes the tags before discovering that.
    let (st, _) = run(ffmpeg, [
        "-v", "error", "-y", "-i", f.path,
        "-map", "0", "-c:v", "copy", "-map_metadata", "0",
        "-af", audioFilter(rate: rate),
        "-compression_level", "12", tmp,
    ], captureStdout: false)
    guard st == 0 else { try? FileManager.default.removeItem(atPath: tmp); return .failure(ResampleError(message: "ffmpeg exit \(st)")) }

    guard let out = FlacInfo(path: tmp) else {
        try? FileManager.default.removeItem(atPath: tmp); return .failure(ResampleError(message: "output is not a readable FLAC"))
    }
    guard out.bitsPerSample == 16, out.sampleRate == rate else {
        try? FileManager.default.removeItem(atPath: tmp)
        return .failure(ResampleError(message: "output is \(out.bitsPerSample)bit/\(out.sampleRate), expected 16bit/\(rate)"))
    }
    // Duration must survive the conversion; a truncated encode would not.
    guard abs(out.duration - f.info.duration) < 0.05 else {
        try? FileManager.default.removeItem(atPath: tmp)
        return .failure(ResampleError(message: String(format: "duration changed %.3fs -> %.3fs", f.info.duration, out.duration)))
    }
    let newSize = ((try? FileManager.default.attributesOfItem(atPath: tmp))?[.size] as? Int64) ?? 0
    guard newSize > 0 else { try? FileManager.default.removeItem(atPath: tmp); return .failure(ResampleError(message: "empty output")) }

    do {
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: f.path),
                                                  withItemAt: URL(fileURLWithPath: tmp))
    } catch {
        try? FileManager.default.removeItem(atPath: tmp)
        return .failure(ResampleError(message: "replace failed: \(error.localizedDescription)"))
    }
    return .success(newSize)
}

var resampleJobs: [(LocalFlac, Int)] = []
for (f, p) in plans {
    switch p {
    case .resampleOnly(let r), .resampleThenUpload(_, let r), .resampleThenReplace(_, let r):
        resampleJobs.append((f, r))
    default: break
    }
}

let lock = NSLock()
var resampled = 0, resampleFailures: [(String, String)] = [], bytesBefore: Int64 = 0, bytesAfter: Int64 = 0

if !resampleJobs.isEmpty {
    print("\nre-encoding \(resampleJobs.count) file(s) with \(o.jobs) job(s) …")
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = o.jobs
    for (f, rate) in resampleJobs {
        queue.addOperation {
            let result = resample(f, to: rate)
            lock.lock()
            switch result {
            case .success(let newSize):
                resampled += 1
                bytesBefore += f.size
                bytesAfter += newSize
                print("  ok   \(f.info.bitsPerSample)bit/\(f.info.sampleRate) -> 16bit/\(rate)  \((f.path as NSString).lastPathComponent)")
            case .failure(let why):
                resampleFailures.append((f.relative, why.message))
                print("  FAIL \(f.relative): \(why.message)")
            }
            lock.unlock()
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    print("re-encoded \(resampled)/\(resampleJobs.count); local \(gb(bytesBefore)) -> \(gb(bytesAfter))")
}

// MARK: - Step 2: upload

guard o.upload else {
    print("\n--no-upload: stopping after re-encode.")
    exit(resampleFailures.isEmpty ? 0 : 1)
}

let failedPaths = Set(resampleFailures.map(\.0))
var uploaded = 0, replaced = 0, uploadFailures: [String] = []

func copyTo(_ local: String, _ remote: String) -> Bool {
    let (st, _) = run(rclone, ["copyto", local, remote, "--retries", "3"],
                      captureStdout: false, showErrors: true)
    return st == 0
}

var mirrorItems: [(dest: String, size: Int64)] = []
for (f, p) in plans where !failedPaths.contains(f.relative) {
    switch p {
    case .upload(let dest), .resampleThenUpload(let dest, _):
        // Re-stat: a re-encoded file is much smaller than the size we planned with.
        let size = ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? Int64) ?? f.size
        mirrorItems.append((dest, size))
    case .resampleThenReplace(let remotePath, _):
        if copyTo(f.path, o.remote + "/" + remotePath) {
            replaced += 1
            print("  replaced \(o.remote)/\(remotePath)")
        } else {
            uploadFailures.append(f.relative)
            print("  FAILED replacing \(remotePath)")
        }
    default: break
    }
}

// Biggest first: the long pole finishes early and the manifest reads usefully.
let mirrorList = writeManifest(mirrorItems, to: o.manifestPath, remote: o.remote)
if !mirrorItems.isEmpty {
    print("upload manifest (\(mirrorItems.count) files, largest first): \(o.manifestPath)")
}

if !mirrorList.isEmpty {
    print("\nuploading \(mirrorList.count) file(s) to \(o.remote) …")
    let listFile = NSTemporaryDirectory() + "muon-cloud-upload.txt"
    try? mirrorList.joined(separator: "\n").write(toFile: listFile, atomically: true, encoding: .utf8)
    // One rclone invocation: it parallelises transfers and recreates the tree.
    var args = ["copy", rootURL.path, o.remote,
                "--files-from-raw", listFile,
                "--order-by", "size,desc",
                "--transfers", "8", "--checkers", "16",
                "--stats", "15s", "--stats-one-line"]
    if !o.logPath.isEmpty { args += ["--log-file", o.logPath, "--log-level", "INFO"] }
    let (st, _) = run(rclone, args, captureStdout: false, showErrors: true)
    if st == 0 { uploaded = mirrorList.count } else { uploadFailures.append("rclone copy exit \(st)") }
}

print("""

done
  re-encoded : \(resampled)   (local \(gb(bytesBefore)) -> \(gb(bytesAfter)))
  uploaded   : \(uploaded)
  replaced   : \(replaced)
  failures   : \(resampleFailures.count + uploadFailures.count)
""")
for (p, why) in resampleFailures { print("  resample failed: \(p) — \(why)") }
for p in uploadFailures { print("  upload failed: \(p)") }
exit(resampleFailures.isEmpty && uploadFailures.isEmpty ? 0 : 1)
