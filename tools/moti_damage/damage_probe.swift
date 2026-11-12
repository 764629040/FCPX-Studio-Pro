// 问题单 C·损坏 .moti 容错验证：真调 MotiDocumentParser.parse，
// 打印 valid / failureReason，6 个坏样本必须全部走可读提示分支。
// 编译：swiftc -O -j 8 <全部源码，排除 main.swift> tools/moti_damage/damage_probe.swift -o <out>
import Foundation

@main
struct DamageProbe {
    static func main() {
        for path in Array(CommandLine.arguments.dropFirst()) {
            let snap = MotiDocumentParser.parse(path: path)
            let name = (path as NSString).lastPathComponent
            if snap.isValid {
                print("OK\t\(name)\tlayers=\(snap.layers.count)")
            } else {
                print("FAIL\t\(name)\t\(snap.failureReason ?? "-")")
            }
        }
    }
}
