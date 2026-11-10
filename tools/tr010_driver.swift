import Foundation

// TR-010 真隔离机制验证驱动（无头）：直接编译真实的 TemplateIsolation.swift，
// 在真实家目录的扫描树/禁用仓上做「禁用→移出扫描树」「启用→搬回」「遗留 *.disabled 迁移」三件事，
// 全部使用 TR010_ 前缀的合成条目，跑完即清理，不污染用户真实模板库。
//
// 编译运行：
//   swiftc -O -o /tmp/tr010_driver \
//     FCPXStudioNative/Sources/FCPXStudio/Models/TemplateIsolation.swift \
//     tools/tr010_driver.swift && /tmp/tr010_driver

func main() throws {
let fm = FileManager.default
let motionRoot = TemplateIsolationStore.motionTemplatesRoot
let disabledRoot = TemplateIsolationStore.disabledRoot

func sh(_ label: String) { print("\n=== \(label) ===") }
func lsDir(_ path: String) {
    guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
        print("  (空或不存在: \(path))")
        return
    }
    for e in entries.sorted() { print("  \(e)") }
}
func wipe(_ path: String) { try? fm.removeItem(atPath: path) }

let titlesScan = (motionRoot as NSString).appendingPathComponent("Titles.localized")
let titlesDisabled = (disabledRoot as NSString).appendingPathComponent("Titles.localized")

// ─────────────────────────────────────────
// Phase A：遗留 *.disabled 一次性迁移
// ─────────────────────────────────────────
let legacyName = "TR010_迁移验证.disabled"
let legacyDir = (titlesScan as NSString).appendingPathComponent(legacyName)
wipe(legacyDir)
try fm.createDirectory(atPath: legacyDir, withIntermediateDirectories: true)
fm.createFile(atPath: (legacyDir as NSString).appendingPathComponent("TR010_迁移验证.moti"),
              contents: Data("dummy".utf8))

sh("A0 迁移前 · 扫描树 Titles.localized（应含 \(legacyName)）")
lsDir(titlesScan)
sh("A0 迁移前 · 禁用仓（应空）")
lsDir(disabledRoot)

do {
    let moved = try TemplateIsolationStore.migrateExistingDisabledInScanTree()
    print("migrateExistingDisabledInScanTree -> moved \(moved.count) 项:")
    for m in moved { print("    \(m.from)  ->  \(m.to)") }
} catch {
    print("迁移异常: \(error.localizedDescription)")
}

sh("A1 迁移后 · 扫描树 Titles.localized（不应再含 \(legacyName)）")
lsDir(titlesScan)
sh("A1 迁移后 · 禁用仓（应含 Titles.localized/TR010_迁移验证）")
lsDir(disabledRoot)

// 清理合成迁移条目
wipe((titlesDisabled as NSString).appendingPathComponent("TR010_迁移验证"))

// ─────────────────────────────────────────
// Phase B：禁用 / 启用 真隔离往返
// ─────────────────────────────────────────
let tplName = "TR010_隔离验证"
let tplDir = (titlesScan as NSString).appendingPathComponent(tplName)
wipe(tplDir)
try fm.createDirectory(atPath: tplDir, withIntermediateDirectories: true)
fm.createFile(atPath: (tplDir as NSString).appendingPathComponent("TR010_隔离验证.moti"),
              contents: Data("dummy".utf8))

sh("B0 禁用前 · 扫描树 Titles.localized（应含 \(tplName)）")
lsDir(titlesScan)

do {
    let disabledPath = try TemplateIsolationStore.disable(templatePath: tplDir)
    print("disable -> \(disabledPath)")
    print("  isDisabled? \(TemplateIsolationStore.isDisabled(path: disabledPath))")
    print("  isInScanTree? \(TemplateIsolationStore.isInScanTree(path: disabledPath))")

    sh("B1 禁用后 · 扫描树 Titles.localized（不应再含 \(tplName)，FCPX 扫不到）")
    lsDir(titlesScan)
    sh("B1 禁用后 · 禁用仓 Titles.localized（应含 \(tplName)）")
    lsDir(titlesDisabled)

    let restored = try TemplateIsolationStore.enable(disabledPath: disabledPath)
    print("enable -> \(restored)")
    print("  isInScanTree? \(TemplateIsolationStore.isInScanTree(path: restored))")
    print("  isDisabled? \(TemplateIsolationStore.isDisabled(path: restored))")

    sh("B2 启用后 · 扫描树 Titles.localized（恢复含 \(tplName)）")
    lsDir(titlesScan)
    sh("B2 启用后 · 禁用仓 Titles.localized（不应再含）")
    lsDir(titlesDisabled)
} catch {
    print("往返异常: \(error.localizedDescription)")
}

// 清理合成隔离条目
wipe(tplDir)
wipe((titlesDisabled as NSString).appendingPathComponent(tplName))

sh("Z 最终 · 禁用仓 Titles.localized（应恢复为空）")
lsDir(titlesDisabled)
print("\nDONE. 所有 TR010_ 合成测试条目已清理，未污染真实模板库。")
}

do { try main() } catch { print("FATAL: \(error.localizedDescription)") }
