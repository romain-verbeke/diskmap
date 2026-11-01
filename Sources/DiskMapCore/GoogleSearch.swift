import Foundation

public enum GoogleSearch {
    /// A search asking whether an item is safe to remove. It uses only the item's name
    /// and its parent folder's name, so the full path and the user name stay private.
    public static func removalQuestionURL(name: String, parentName: String?, isFolder: Bool) -> URL? {
        var question = "Can I safely delete the \"\(name)\" \(isFolder ? "folder" : "file")"
        if let parentName, !parentName.isEmpty {
            question += " in \"\(parentName)\""
        }
        question += " on a Mac?"

        guard var components = URLComponents(string: "https://www.google.com/search") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: question)]
        // URLComponents leaves "+" as is, and Google would read it as a space.
        let encoded = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = encoded
        return components.url
    }
}
