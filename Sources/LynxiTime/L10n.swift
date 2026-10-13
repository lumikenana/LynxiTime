import Foundation

/// 本地化字符串快捷入口（界面语言：英文 / 简体中文）
enum L10n {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: key, comment: "")
    }
}
