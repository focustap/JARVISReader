import MWDATDisplay

enum JARVISDisplayViews {
    static func ready(onTap: @escaping () -> Void) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            Text("JARVIS", style: .heading)
            Text("Tap to scan", style: .body)
        }
        .padding(24)
        .background(.card)
        .onTap(onTap)
    }

    static func working(_ message: String = "Reading image…") -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            Text("JARVIS", style: .heading)
            Text(message, style: .body)
        }
        .padding(24)
        .background(.card)
    }

    static func answer(_ answer: String, onTap: @escaping () -> Void) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 10) {
            Text(answer, style: .body)
            Text("Tap to scan again", style: .body)
        }
        .padding(20)
        .background(.card)
        .onTap(onTap)
    }

    static func error(_ message: String, onTap: @escaping () -> Void) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 10) {
            Text("JARVIS error", style: .heading)
            Text(message, style: .body)
            Text("Tap to retry", style: .body)
        }
        .padding(20)
        .background(.card)
        .onTap(onTap)
    }
}
