import Foundation
import SwiftParser
import SwiftSyntax

struct Literal: Codable {
    let path: String
    let line: Int
    let column: Int
    let start: Int
    let end: Int
    let raw: String
    let value: String?
    let fragments: String
    let calls: [String]
    let owners: [String]
    let labels: [String]
    let kinds: [String]
}

final class Collector: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    var records: [Literal] = []
    init(path: String, tree: SourceFileSyntax) {
        self.path = path
        converter = SourceLocationConverter(fileName: path, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        var calls: [String] = [], owners: [String] = [], labels: [String] = [], kinds: [String] = []
        var ancestor = node.parent
        for _ in 0..<40 {
            guard let parent = ancestor else { break }
            kinds.append(String(describing: parent.kind))
            if let call = parent.as(FunctionCallExprSyntax.self) { calls.append(String(call.calledExpression.trimmedDescription.prefix(120))) }
            if let function = parent.as(FunctionDeclSyntax.self) { owners.append("func:" + function.name.text) }
            if let binding = parent.as(PatternBindingSyntax.self) { owners.append("var:" + binding.pattern.trimmedDescription) }
            if let argument = parent.as(LabeledExprSyntax.self), let label = argument.label { labels.append(label.text) }
            if let named = parent.as(StructDeclSyntax.self) { owners.append("type:" + named.name.text) }
            if let named = parent.as(EnumDeclSyntax.self) { owners.append("type:" + named.name.text) }
            if let named = parent.as(ClassDeclSyntax.self) { owners.append("type:" + named.name.text) }
            ancestor = parent.parent
        }
        let fragments = node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
        records.append(Literal(path: path, line: location.line, column: location.column,
            start: node.positionAfterSkippingLeadingTrivia.utf8Offset, end: node.endPositionBeforeTrailingTrivia.utf8Offset,
            raw: node.trimmedDescription, value: node.representedLiteralValue, fragments: fragments,
            calls: calls, owners: owners, labels: labels, kinds: kinds))
        return .visitChildren
    }
}

var records: [Literal] = []
for root in ["Imora", "ImoraShare", "Shared"] {
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
    for case let relative as String in enumerator where relative.hasSuffix(".swift") {
        let path = root + "/" + relative
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let collector = Collector(path: path, tree: tree)
        collector.walk(tree)
        records += collector.records
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(records))
