import Foundation

extension String {
    /// Grapheme-safe chunks used to insert cancellation boundaries into a long
    /// XCTest text-synthesis call.
    func chunksForAutomation(maximumCount: Int) -> [String] {
        guard maximumCount > 0, !isEmpty else {
            return isEmpty ? [] : [self]
        }
        var output: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(
                start,
                offsetBy: maximumCount,
                limitedBy: endIndex
            ) ?? endIndex
            output.append(String(self[start..<end]))
            start = end
        }
        return output
    }
}
