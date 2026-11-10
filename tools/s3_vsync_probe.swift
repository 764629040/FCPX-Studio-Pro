import Foundation
import CoreVideo

// S3 / P1 —— CVDisplayLink 真实刷新周期探针（独立小工具，不进主 harness 编译单元）。
// 用途：用真实显示器的 nominal output video refresh period 校准 harness 的 vsync 节拍预算。
// 若本探针在当前会话不可用，run.sh 回退到固定 16.6667ms（60Hz），并在证据里如实记录。
// 单文件 swiftc 编译时按 main.swift「顶层代码」模式处理，直接用顶层语句，不用 @main。
var link: CVDisplayLink?
let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
if status == kCVReturnSuccess, let dl = link {
    let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(dl)
    CVDisplayLinkStop(dl)
    if period.timeScale > 0 && period.timeValue > 0 {
        let ms = Double(period.timeValue) / Double(period.timeScale) * 1000.0
        print(String(format: "CVDisplayLink: OK nominalPeriodMs=%.6f timeValue=%lld timeScale=%d",
                     ms, period.timeValue, period.timeScale))
    } else {
        print("CVDisplayLink: NO_PERIOD timeValue=\(period.timeValue) timeScale=\(period.timeScale) fallback_nominalPeriodMs=16.666667")
    }
} else {
    print("CVDisplayLink: UNAVAILABLE status=\(status) fallback_nominalPeriodMs=16.666667")
}
