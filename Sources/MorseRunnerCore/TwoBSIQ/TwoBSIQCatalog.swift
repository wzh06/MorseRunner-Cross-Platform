import Foundation

/// CQ WW training data shared by the two simulated bands.
@MainActor
public struct TwoBSIQCatalog {
    public static let bundled = TwoBSIQCatalog(history: DataFiles.loadString("CQWWCW.txt") ?? "")

    struct Station: Equatable {
        let call: String
        let zone: Int
        let entity: String
        let continent: String
    }

    private let zonesByCall: [String: Set<Int>]
    let stations: [Station]

    init(history: String) {
        var zonesByCall: [String: Set<Int>] = [:]
        for line in history.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count >= 2,
                  let zone = Int(columns[1].trimmingCharacters(in: .whitespaces)),
                  (1...40).contains(zone) else { continue }
            let call = Self.normalizedCall(String(columns[0]))
            guard Self.isCall(call) else { continue }
            zonesByCall[call, default: []].insert(zone)
        }

        self.zonesByCall = zonesByCall
        stations = zonesByCall.keys.sorted().compactMap { call in
            guard (3...6).contains(call.count), !call.contains("/"),
                  let zones = zonesByCall[call], zones.count == 1, let zone = zones.first,
                  let location = Self.location(for: call) else { return nil }
            return Station(call: call, zone: zone, entity: location.entity, continent: location.continent)
        }
    }

    public var isEmpty: Bool { stations.isEmpty }

    public func zone(for input: String) -> Int? {
        let call = Self.normalizedCall(input)
        guard Self.isCall(call) else { return nil }
        if let zones = zonesByCall[call] {
            return zones.count == 1 ? zones.first : nil
        }

        guard let location = Self.location(for: call) else { return nil }
        if location.entity == "China" {
            let prefix = CallsignUtils.extractPrefix(call, deleteTrailingLetters: false)
            return Self.mainlandChinaZone(prefix)
        }
        // A location with multiple zones needs an exact call or operator input.
        guard let zone = Int(location.cq), (1...40).contains(zone) else { return nil }
        return zone
    }

    public static func normalizedCall(_ call: String) -> String {
        call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func isCall(_ call: String) -> Bool {
        let parts = call.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return (3...24).contains(call.count)
            && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
            && parts.contains(where: hasCallCharacters)
    }

    private static func hasCallCharacters(_ part: Substring) -> Bool {
        part.count >= 3 && part.contains(where: \.isNumber) && part.contains(where: \.isLetter)
    }

    static func location(for call: String) -> DxccRec? {
        Dxcc.shared.findRec(call)
    }

    /// CQ WW WAZ definitions for the BY districts, also used by mainland
    /// personal calls with the same district and provincial suffix ranges.
    private static func mainlandChinaZone(_ call: String) -> Int? {
        let letters = Array(call)
        guard letters.count > 2, letters[0] == "B" else { return nil }
        let districtIndex = letters[1].isNumber ? 1 : 2
        let district = letters[districtIndex]
        let suffix = letters.dropFirst(districtIndex + 1).first
        switch district {
        case "0": return 23
        case "1", "2", "4", "5", "6", "7", "8": return 24
        case "3":
            guard let suffix, ("A"..."X").contains(suffix) else { return nil }
            return ("G"..."L").contains(suffix) ? 23 : 24
        case "9":
            guard let suffix, ("A"..."Z").contains(suffix) else { return nil }
            return ("A"..."F").contains(suffix) ? 24 : 23
        default: return nil
        }
    }
}
