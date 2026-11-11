import SwiftUI

private enum Key: Hashable {
    case digit(Int)
    case decimal, equals, clear, sign, percent
    case op(Operation)
}

struct ContentView: View {
    @StateObject private var model = CalculatorModel()

    private let spacing: CGFloat = 12
    private let sidePadding: CGFloat = 16

    private let rows: [[Key]] = [
        [.clear, .sign, .percent, .op(.divide)],
        [.digit(7), .digit(8), .digit(9), .op(.multiply)],
        [.digit(4), .digit(5), .digit(6), .op(.subtract)],
        [.digit(1), .digit(2), .digit(3), .op(.add)],
        [.digit(0), .decimal, .equals]
    ]

    var body: some View {
        GeometryReader { geo in
            let side = buttonSide(for: geo.size)
            VStack(spacing: spacing) {
                Spacer(minLength: 0)

                Text(displayText)
                    .font(.system(size: 88, weight: .light))
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .gesture(swipeToDelete)
                    .accessibilityLabel(displayText)

                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(rows[r], id: \.self) { key in
                            keyButton(key, side: side)
                        }
                    }
                }
            }
            .padding(.horizontal, sidePadding)
            .padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var displayText: String {
        model.display.replacingOccurrences(of: ".", with: ",")
    }

    /// Свайп по экрану влево/вправо стирает последнюю цифру.
    private var swipeToDelete: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { value in
            if abs(value.translation.width) > abs(value.translation.height) {
                model.backspace()
            }
        }
    }

    private func buttonSide(for size: CGSize) -> CGFloat {
        let byWidth = (size.width - 2 * sidePadding - 3 * spacing) / 4
        let byHeight = (size.height - 5 * spacing - 140) / 5
        return max(40, min(byWidth, byHeight))
    }

    @ViewBuilder
    private func keyButton(_ key: Key, side: CGFloat) -> some View {
        let isZero = key == .digit(0)
        let width = isZero ? side * 2 + spacing : side
        let palette = colors(for: key)

        Button {
            handle(key)
        } label: {
            ZStack(alignment: isZero ? .leading : .center) {
                Capsule().fill(palette.bg)
                Text(title(for: key))
                    .font(.system(size: side * 0.42, weight: .regular))
                    .foregroundColor(palette.fg)
                    .padding(.leading, isZero ? side * 0.38 : 0)
            }
            .frame(width: width, height: side)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(spokenTitle(for: key))
    }

    private func handle(_ key: Key) {
        switch key {
        case .digit(let d): model.inputDigit(d)
        case .decimal: model.inputDecimal()
        case .equals: model.equals()
        case .clear: model.clear()
        case .sign: model.toggleSign()
        case .percent: model.percent()
        case .op(let o): model.operation(o)
        }
    }

    private func title(for key: Key) -> String {
        switch key {
        case .digit(let d): return String(d)
        case .decimal: return ","
        case .equals: return "="
        case .clear: return model.clearTitle
        case .sign: return "±"
        case .percent: return "%"
        case .op(let o): return o.symbol
        }
    }

    private func spokenTitle(for key: Key) -> String {
        switch key {
        case .digit(let d): return String(d)
        case .decimal: return "запятая"
        case .equals: return "равно"
        case .clear: return model.clearTitle == "C" ? "стереть" : "сбросить всё"
        case .sign: return "сменить знак"
        case .percent: return "процент"
        case .op(let o): return o.spokenName
        }
    }

    private func colors(for key: Key) -> (bg: Color, fg: Color) {
        let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
        switch key {
        case .clear, .sign, .percent:
            return (Color(white: 0.65), Color.black)
        case .op(let o):
            if model.activeOperation == o { return (Color.white, orange) }
            return (orange, Color.white)
        case .equals:
            return (orange, Color.white)
        case .digit, .decimal:
            return (Color(white: 0.2), Color.white)
        }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
