import Foundation
import UniformTypeIdentifiers

/// Decides which finished downloads may be opened automatically.
public enum DownloadSafety {
    /// True only for plain media and documents: images, PDF, audio, video and plain text.
    /// Executables, apps, scripts, source code, disk images, archives, packages and anything
    /// unrecognised are refused. Only the last extension counts ("photo.jpg.app" is an app).
    public static func isSafeToOpen(filename: String) -> Bool {
        let name = (filename as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, !deniedExtensions.contains(ext),
              let type = UTType(filenameExtension: ext) else { return false }
        if deniedTypes.contains(where: { type.conforms(to: $0) }) { return false }
        return allowedTypes.contains { type.conforms(to: $0) }
    }

    private static let allowedTypes: [UTType] = [.image, .pdf, .audio, .movie, .video, .plainText]

    private static let deniedTypes: [UTType] = [
        .executable, .unixExecutable, .application, .applicationBundle, .applicationExtension,
        .script, .shellScript, .sourceCode, .diskImage, .archive, .package, .bundle, .aliasFile,
        .symbolicLink, .url, .internetLocation, .html, .xml, .svg,
    ]

    /// Belt and braces for types the system may not know or may classify loosely.
    private static let deniedExtensions: Set<String> = [
        "app", "command", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "tool", "terminal", "workflow",
        "action", "scpt", "scptd", "applescript", "osa", "js", "jse", "mjs", "py", "pl", "rb", "php", "ps1",
        "bat", "cmd", "com", "exe", "msi", "dll", "scr", "vbs", "wsf", "jar", "class", "dmg", "iso", "img",
        "sparseimage", "sparsebundle", "pkg", "mpkg", "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "z",
        "xip", "webloc", "inetloc", "fileloc", "url", "html", "htm", "xhtml", "svg", "svgz", "webarchive", "swf",
        "mobileconfig", "configprofile", "plugin", "prefpane", "saver", "kext", "xpc", "appex", "docm", "xlsm",
        "pptm", "lnk", "pif", "hta", "reg", "inf",
    ]
}
