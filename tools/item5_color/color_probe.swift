// 第 5 项·文字取色补「面/渐变」验证：Swift 真调 MotiDocumentParser，
// 逐层打印 textColor / colorSourcePath，供 39 层样本与全库对账。
// 编译：swiftc -O -j 8 <全部源码，排除 main.swift> tools/item5_color/color_probe.swift -o <out>
import Foundation

@main
struct ColorProbe {
    static func main() {
        for p in Array(CommandLine.arguments.dropFirst()) {
            let s = MotiDocumentParser.parse(path: p)
            for l in s.layers {
                let text = l.text.replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                print("ROW\t\(p)\t\(l.id)\t\(l.textColor.isEmpty ? "-" : l.textColor)\t\(l.colorSourcePath.isEmpty ? "-" : l.colorSourcePath)\t\(text)")
            }
        }
    }
}
