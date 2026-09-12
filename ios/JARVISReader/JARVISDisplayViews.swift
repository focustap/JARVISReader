import MWDATDisplay

enum JARVISDisplayViews {
    static func ready(onTap: @escaping @Sendable () -> Void) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 14) {
            Text("JARVIS", style: .heading)
            Text("Ready to read what you are looking at.", style: .body)
            ButtonGroup {
                Button(label: "Capture & Ask", style: .primary, onClick: onTap)
            }
        }
        .padding(24)
        .background(.card)
    }

    static func working(_ message: String = "Reading image…") -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            Text("JARVIS", style: .heading)
            Text(message, style: .body)
        }
        .padding(24)
        .background(.card)
    }

    static func answer(_ answer: String, onTap: @escaping @Sendable () -> Void) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            Text(answer, style: .body)
            ButtonGroup {
                Button(label: "Capture Again", style: .primary, onClick: onTap)
            }
        }
        .padding(20)
        .background(.card)
    }

    static func error(_ message: String, onTap: @escaping @Sendable () -> Void) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            Text("JARVIS error", style: .heading)
            Text(message, style: .body)
            ButtonGroup {
                Button(label: "Retry", style: .primary, onClick: onTap)
            }
        }
        .padding(20)
        .background(.card)
    }
}
