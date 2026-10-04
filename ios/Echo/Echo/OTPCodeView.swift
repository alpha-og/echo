import SwiftUI

/// Segmented one-time-code entry: six distinct digit boxes over one hidden
/// field. Handles typing, deletion, and paste; filters to digits, caps length.
struct OTPCodeView: View {
    @Binding var code: String
    var length = 6
    var shakeTrigger = 0
    var onComplete: (() -> Void)?

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakeX: CGFloat = 0
    @State private var submittedFor = ""

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<length, id: \.self) { i in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(borderColor(for: i), lineWidth: 1.5)
                    Text(digit(at: i))
                        .font(.title2.monospacedDigit())
                }
                .frame(width: 44, height: 52)
            }
        }
        .offset(x: shakeX)
        .onChange(of: shakeTrigger) {
            guard !reduceMotion, shakeTrigger > 0 else { return }
            withAnimation(.linear(duration: 0.05).repeatCount(5, autoreverses: true)) {
                shakeX = 6
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shakeX = 0 }
        }
        .overlay {
            // Invisible field captures the keyboard; boxes render the digits.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .opacity(0.02)
                .onChange(of: code) {
                    let clean = String(code.filter(\.isNumber).prefix(length))
                    if clean != code { code = clean }
                    if clean.count == length, clean != submittedFor {
                        submittedFor = clean
                        onComplete?()
                    } else if clean.count < length {
                        submittedFor = ""
                    }
                }
        }
        .onTapGesture { focused = true }
        .onAppear { focused = true }
    }

    private func digit(at i: Int) -> String {
        let chars = Array(code)
        return i < chars.count ? String(chars[i]) : ""
    }

    private func borderColor(for i: Int) -> Color {
        if code.count == length { return .green }
        if i == code.count { return .accentColor }
        return .secondary.opacity(0.4)
    }
}
