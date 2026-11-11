import Foundation

enum Operation: Hashable {
    case add, subtract, multiply, divide

    var symbol: String {
        switch self {
        case .add: return "+"
        case .subtract: return "−"
        case .multiply: return "×"
        case .divide: return "÷"
        }
    }

    var spokenName: String {
        switch self {
        case .add: return "плюс"
        case .subtract: return "минус"
        case .multiply: return "умножить"
        case .divide: return "разделить"
        }
    }

    /// Возвращает nil, если результат не имеет смысла (деление на ноль, переполнение).
    func apply(_ a: Double, _ b: Double) -> Double? {
        let result: Double
        switch self {
        case .add: result = a + b
        case .subtract: result = a - b
        case .multiply: result = a * b
        case .divide:
            if b == 0 { return nil }
            result = a / b
        }
        return result.isFinite ? result : nil
    }
}

final class CalculatorModel: ObservableObject {
    @Published private(set) var display = "0"
    @Published private(set) var activeOperation: Operation?

    private var storedValue: Double?
    private var pendingOperation: Operation?
    private var lastOperation: Operation?
    private var lastOperand: Double?

    /// true — пользователь сейчас набирает число (цифры дописываются).
    private var isEntering = true
    /// true — на экране число, которое можно использовать как операнд.
    private var hasFreshOperand = true
    private var hasError = false
    private let maxDigits = 9

    var clearTitle: String {
        (display != "0" && !hasError) ? "C" : "AC"
    }

    private var currentValue: Double {
        var text = display
        if text.hasSuffix(".") { text.removeLast() }
        return Double(text) ?? 0
    }

    // MARK: - Ввод

    func inputDigit(_ digit: Int) {
        prepare()
        activeOperation = nil
        if isEntering {
            if display == "0" {
                display = String(digit)
            } else if display == "-0" {
                display = "-" + String(digit)
            } else if display.filter({ $0.isNumber }).count < maxDigits {
                display += String(digit)
            }
        } else {
            display = String(digit)
            isEntering = true
        }
        hasFreshOperand = true
    }

    func inputDecimal() {
        prepare()
        activeOperation = nil
        if !isEntering {
            display = "0."
            isEntering = true
        } else if !display.contains(".") {
            display += "."
        }
        hasFreshOperand = true
    }

    func toggleSign() {
        prepare()
        if display.hasPrefix("-") {
            display.removeFirst()
        } else {
            display = "-" + display
        }
        hasFreshOperand = true
    }

    func percent() {
        prepare()
        let value = currentValue
        var result = value / 100
        if let pending = pendingOperation, let stored = storedValue,
           pending == .add || pending == .subtract {
            result = stored * value / 100
        }
        guard result.isFinite else { fail(); return }
        display = format(result)
        isEntering = false
        hasFreshOperand = true
        activeOperation = nil
    }

    func backspace() {
        guard !hasError, isEntering else { return }
        display.removeLast()
        if display.isEmpty || display == "-" || display == "-0" {
            display = "0"
        }
    }

    func clear() {
        if clearTitle == "C" {
            display = "0"
            isEntering = true
            hasFreshOperand = true
        } else {
            reset()
        }
    }

    // MARK: - Операции

    func operation(_ op: Operation) {
        prepare()
        if let pending = pendingOperation, let stored = storedValue, hasFreshOperand {
            // Цепочка вида 2 + 3 × ...: сначала считаем промежуточный результат.
            guard let result = pending.apply(stored, currentValue) else { fail(); return }
            display = format(result)
            storedValue = result
        } else if pendingOperation == nil {
            storedValue = currentValue
        }
        pendingOperation = op
        activeOperation = op
        lastOperation = nil
        isEntering = false
        hasFreshOperand = false
    }

    func equals() {
        prepare()
        if let pending = pendingOperation, let stored = storedValue {
            let rhs = currentValue
            guard let result = pending.apply(stored, rhs) else { fail(); return }
            display = format(result)
            lastOperation = pending
            lastOperand = rhs
        } else if let op = lastOperation, let rhs = lastOperand {
            // Повторное нажатие «=» повторяет последнюю операцию.
            guard let result = op.apply(currentValue, rhs) else { fail(); return }
            display = format(result)
        }
        pendingOperation = nil
        storedValue = nil
        activeOperation = nil
        isEntering = false
        hasFreshOperand = true
    }

    // MARK: - Служебное

    private func prepare() {
        if hasError { reset() }
    }

    private func reset() {
        display = "0"
        activeOperation = nil
        storedValue = nil
        pendingOperation = nil
        lastOperation = nil
        lastOperand = nil
        isEntering = true
        hasFreshOperand = true
        hasError = false
    }

    private func fail() {
        reset()
        display = "Ошибка"
        hasError = true
    }

    private func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 {
            return String(Int64(value))
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 9
        let magnitude = abs(value)
        formatter.numberStyle = (magnitude >= 1e9 || magnitude < 1e-6) ? .scientific : .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 9
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
