import SwiftUI

enum AgentPanelMotion {
    static func reveal(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.10)
            : .snappy(duration: 0.18, extraBounce: 0)
    }
}
