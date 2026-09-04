import CoreGraphics

struct DDCOperationGeneration {
    struct Token: Equatable {
        let topology: UInt64
        let request: UInt64
    }

    private var topologies: [CGDirectDisplayID: UInt64] = [:]
    private var requests: [CGDirectDisplayID: UInt64] = [:]

    func currentToken(for displayID: CGDirectDisplayID) -> Token {
        Token(
            topology: topologies[displayID, default: 0],
            request: requests[displayID, default: 0]
        )
    }

    mutating func nextRequest(for displayID: CGDirectDisplayID) -> Token {
        requests[displayID, default: 0] &+= 1
        return currentToken(for: displayID)
    }

    mutating func invalidate(displayID: CGDirectDisplayID) {
        topologies[displayID, default: 0] &+= 1
        requests[displayID, default: 0] &+= 1
    }

    func isCurrentTopology(_ token: Token, for displayID: CGDirectDisplayID) -> Bool {
        token.topology == topologies[displayID, default: 0]
    }

    func isLatestRequest(_ token: Token, for displayID: CGDirectDisplayID) -> Bool {
        isCurrentTopology(token, for: displayID)
            && token.request == requests[displayID, default: 0]
    }
}
