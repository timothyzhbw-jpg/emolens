import EmoLensCore
import SwiftUI

/// 配色、图标与文案映射。情绪颜色偏柔和，严重信号才用红色。
enum Theme {
    static let brand = LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.55), Color(red: 0.99, green: 0.66, blue: 0.36)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
    static let reply = Color(red: 0.36, green: 0.78, blue: 0.40)
    static let care = Color(red: 0.20, green: 0.62, blue: 0.70)
    static let danger = Color(red: 0.88, green: 0.27, blue: 0.30)

    static func color(for emotion: String) -> Color {
        switch emotion {
        case "开心": Color(red: 0.95, green: 0.66, blue: 0.16)
        case "平静": Color(red: 0.45, green: 0.56, blue: 0.70)
        case "亲昵": Color(red: 0.94, green: 0.40, blue: 0.60)
        case "难过": Color(red: 0.27, green: 0.50, blue: 0.86)
        case "委屈": Color(red: 0.56, green: 0.44, blue: 0.86)
        case "生气": Color(red: 0.88, green: 0.29, blue: 0.29)
        case "失望": Color(red: 0.44, green: 0.49, blue: 0.60)
        case "焦虑": Color(red: 0.92, green: 0.52, blue: 0.20)
        case "冷淡": Color(red: 0.33, green: 0.62, blue: 0.70)
        case "尴尬": Color(red: 0.92, green: 0.47, blue: 0.38)
        default: .accentColor
        }
    }

    static func emoji(for emotion: String) -> String {
        ["开心": "😊", "平静": "🙂", "亲昵": "🥰", "难过": "😢", "委屈": "🥺", "生气": "😠",
         "失望": "😞", "焦虑": "😟", "冷淡": "😶", "尴尬": "😳"][emotion] ?? "💬"
    }

    static func intensityLabel(_ value: Double) -> String {
        ["几乎没有", "轻微", "明显", "很强烈"][Int(min(3, max(0, value.rounded())))]
    }

    static func responseSymbol(_ response: String) -> String {
        switch response {
        case "安慰共情": "heart.circle"
        case "真诚道歉": "hand.raised"
        case "解释澄清": "text.bubble"
        case "给对方空间": "leaf"
        case "用行动关心": "phone"
        case "正常聊天": "bubble.left.and.bubble.right"
        case "守住边界": "shield.lefthalf.filled"
        case "核实身份": "checkmark.shield"
        case "寻求帮助": "lifepreserver"
        default: "lightbulb"
        }
    }
}

extension EmotionFlag {
    var symbol: String {
        switch self {
        case .angryAtMe: "flame"
        case .sarcasm: "theatermasks"
        case .perfunctory: "ellipsis.bubble"
        case .needsComfort: "heart"
        case .testing: "questionmark.bubble"
        case .coldDistance: "snowflake"
        case .conflict: "heart.slash"
        case .manipulation: "exclamationmark.shield"
        case .selfHarm: "cross.case"
        case .asksMoney: "creditcard.trianglebadge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .needsComfort: Theme.care
        case .sarcasm, .testing: Color(red: 0.55, green: 0.42, blue: 0.86)
        case .coldDistance, .perfunctory: Color(red: 0.40, green: 0.52, blue: 0.66)
        case .angryAtMe: Color(red: 0.92, green: 0.50, blue: 0.20)
        case .conflict, .manipulation, .selfHarm: Theme.danger
        case .asksMoney: Color(red: 0.85, green: 0.55, blue: 0.10)
        }
    }
}

/// 卡片底色：亮色模式下是浅灰，暗色模式下是浅白，都靠透明度适配。
struct CardBackground: ViewModifier {
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background((tint ?? .primary).opacity(tint == nil ? 0.045 : 0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((tint ?? .primary).opacity(tint == nil ? 0.07 : 0.18), lineWidth: 0.5))
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(CardBackground(tint: tint)) }
}
