// TR-019-R：Swift 真调 MotiDocumentParser，输出机器可读 TSV，供层数对照表消费。
// 编译见 tools/tr019r/verify_layers.sh（全量源码 + 本文件，排除 main.swift）。
import Foundation

@main
struct ParseProbe {
    static func main() {
        for p in Array(CommandLine.arguments.dropFirst()) {
            let s = MotiDocumentParser.parse(path: p)
            let names = s.layers.map { $0.name }.joined(separator: "|")
            print("RESULT\t\(p)\tvalid=\(s.isValid)\tlayers=\(s.layers.count)\tnested=\(s.nestedLayerCount)\tcanvas=\(s.canvasWidth)x\(s.canvasHeight)\tnames=\(names)")
        }
    }
}
