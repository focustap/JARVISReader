import MWDATDisplay

enum JARVISDisplayViews {
    static func ready(
        onSingleTap: @escaping @Sendable () -> Void,
        onContextTap: @escaping @Sendable () -> Void
    ) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 14) {
            Text("JARVIS", style: .heading)
            Text("Choose how you want to scan.", style: .body)
            ButtonGroup {
                Button(label: "One Photo", style: .primary, onClick: onSingleTap)
                Button(label: "Context Mode", style: .secondary, onClick: onContextTap)
            }
        }
        .padding(24)
        .background(.card)
    }

    static func contextSaved(onTap: @escaping @Sendable () -> Void) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            Text("Context saved", style: .heading)
            Text("Aim at the question, then capture the second photo.", style: .body)
            ButtonGroup {
                Button(label: "Capture Question", style: .primary, onClick: onTap)
            }
        }
        .padding(20)
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

    static func answer(
        _ answer: String,
        onSingleTap: @escaping @Sendable () -> Void,
        onContextTap: @escaping @Sendable () -> Void
    ) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            Text(answer, style: .body)
            ButtonGroup {
                Button(label: "One Photo", style: .primary, onClick: onSingleTap)
                Button(label: "Context Mode", style: .secondary, onClick: onContextTap)
            }
        }
        .padding(20)
        .background(.card)
    }

    static func error(
        _ message: String,
        onRetry: @escaping @Sendable () -> Void
    ) -> some DisplayableView {
        FlexBox(direction: .column, spacing: 12) {
            Text("JARVIS error", style: .heading)
            Text(message, style: .body)
            ButtonGroup {
                Button(label: "Retry", style: .primary, onClick: onRetry)
            }
        }
        .padding(20)
        .background(.card)
    }
}
