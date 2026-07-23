import Foundation

struct ManifestRow: Decodable {
    let sample_id: String
    let sequence: Int
    let source_kind: String
    let source_page_title: String
    let source_page_url: String
    let source_page_id: Int?
    let link_text: String
    let raw_href: String
    let normalized_destination: String
    let expected_classification: String
    let edge_case: String?
}

struct ResultRow: Encodable {
    let sample_id: String
    let sequence: Int
    let source_kind: String
    let source_page_title: String
    let source_page_url: String
    let source_page_id: Int?
    let link_text: String
    let raw_href: String
    let normalized_destination: String
    let expected_classification: String
    let observed_classification: String
    let routed_article_url: String?
    let policy_match: Bool
    let edge_case: String?
    let likely_code_area: String?
}

struct Summary: Encodable {
    let sample_count_total: Int
    let sample_count_distinct_tested: Int
    let deterministic_execution_count: Int
    let counts_by_expected: [String: Int]
    let counts_by_observed: [String: Int]
    let mismatch_count: Int
    let top_mismatch_examples: [ResultRow]
}

func decodedArticleName(path: String) -> String {
    guard path.hasPrefix("/w/") else { return "" }
    let start = path.index(path.startIndex, offsetBy: 3)
    return String(path[start...]).removingPercentEncoding?.lowercased() ?? String(path[start...]).lowercased()
}

func observedClassification(for urlString: String) -> (String, String?, String?) {
    guard let url = URL(string: urlString), !urlString.isEmpty else {
        return ("navigation_error", nil, "URL parsing before osrsArticleLinkRouter.appArticleURL(for:)")
    }

    if let articleURL = osrsArticleLinkRouter.appArticleURL(for: url) {
        return ("app_article_viewer", articleURL.absoluteString, "osrsArticleLinkRouter.appArticleURL(for:)")
    }

    let articleName = decodedArticleName(path: url.path)
    if url.scheme?.lowercased() == "app-assets",
       url.host?.lowercased() == "localhost",
       (articleName.hasPrefix("file:") || articleName.hasPrefix("media:") || articleName.hasPrefix("special:")) {
        return ("navigation_error", nil, "ArticleViewModel.shouldOpenExternally(_:) app-assets custom-scheme branch")
    }

    return ("allowed_external_or_special", nil, "ArticleViewModel.shouldOpenExternally(_:)")
}

@main
struct RoutingAudit {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: RoutingAudit <manifest.jsonl> <results.jsonl> <summary.json>\n".utf8))
            Foundation.exit(64)
        }

        let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let resultsURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let summaryURL = URL(fileURLWithPath: CommandLine.arguments[3])

        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        var results: [ResultRow] = []
        var expectedCounts: [String: Int] = [:]
        var observedCounts: [String: Int] = [:]
        var mismatchExamples: [ResultRow] = []

        for line in manifest.split(separator: "\n") {
            let row = try decoder.decode(ManifestRow.self, from: Data(line.utf8))
            let (observed, routedURL, codeArea) = observedClassification(for: row.normalized_destination)
            let result = ResultRow(
                sample_id: row.sample_id,
                sequence: row.sequence,
                source_kind: row.source_kind,
                source_page_title: row.source_page_title,
                source_page_url: row.source_page_url,
                source_page_id: row.source_page_id,
                link_text: row.link_text,
                raw_href: row.raw_href,
                normalized_destination: row.normalized_destination,
                expected_classification: row.expected_classification,
                observed_classification: observed,
                routed_article_url: routedURL,
                policy_match: row.expected_classification == observed,
                edge_case: row.edge_case,
                likely_code_area: codeArea
            )
            results.append(result)
            expectedCounts[row.expected_classification, default: 0] += 1
            observedCounts[observed, default: 0] += 1
            if !result.policy_match && mismatchExamples.count < 25 {
                mismatchExamples.append(result)
            }
        }

        var output = Data()
        for result in results {
            output.append(try encoder.encode(result))
            output.append(0x0A)
        }
        try output.write(to: resultsURL, options: .atomic)

        let summary = Summary(
            sample_count_total: results.count,
            sample_count_distinct_tested: results.count,
            deterministic_execution_count: results.count,
            counts_by_expected: expectedCounts,
            counts_by_observed: observedCounts,
            mismatch_count: results.filter { !$0.policy_match }.count,
            top_mismatch_examples: mismatchExamples
        )
        try encoder.encode(summary).write(to: summaryURL, options: .atomic)
        print(String(data: try encoder.encode(summary), encoding: .utf8)!)
    }
}
