import Foundation

extension ImportSource {
    /// How to save this browser's passwords as a CSV file, in plain steps for Settings.
    public var passwordExportSteps: String {
        switch self {
        case .safari:
            "Open the Passwords app and choose File ▸ Export All Passwords. Safari's passwords live there."
        case .chrome:
            "In Chrome, open chrome://password-manager/settings, choose Export passwords, then Download file."
        case .edge:
            "In Edge, open edge://wallet/passwords, choose ••• ▸ Export passwords, then confirm."
        case .brave:
            "In Brave, open brave://password-manager/settings, choose Export passwords, then Download file."
        case .arc:
            "In Arc, open arc://password-manager/settings, choose Export passwords, then Download file."
        case .vivaldi:
            "In Vivaldi, open vivaldi://password-manager/settings, choose Export passwords, then Download file."
        case .opera:
            "In Opera, open opera://password-manager/settings, choose Export passwords, then Download file."
        case .chromium:
            "In Chromium, open chrome://password-manager/settings, choose Export passwords, then Download file."
        case .firefox:
            "In Firefox, open about:logins, choose ••• ▸ Export Passwords, then confirm."
        case .zen:
            "In Zen, open about:logins, choose ••• ▸ Export Passwords, then confirm."
        }
    }
}
