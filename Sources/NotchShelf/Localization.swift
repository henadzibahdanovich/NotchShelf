import Foundation

/// Перевод строки интерфейса. Ключ — английский текст; переводы лежат в *.lproj/Localizable.strings.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Перевод строки с подстановками (%@, %1$@ …). Все аргументы — строки.
func L(_ key: String, _ args: String...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args.map { $0 as NSString as CVarArg })
}
