import Foundation
import StikJIT

@objc(AMJITHandler)
final class AMJITHandler: NSObject, NSExtensionRequestHandling {
    private static let work = DispatchQueue(label: "amethyst.stikjit.serial")

    func beginRequest(with context: NSExtensionContext) {
        let payload = (context.inputItems.first as? NSExtensionItem)?.userInfo ?? [:]
        Self.work.async {
            let result = Self.execute(payload)
            let item = NSExtensionItem()
            item.userInfo = result
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }

    private static func execute(_ payload: [AnyHashable: Any]) -> [AnyHashable: Any] {
        do {
            let fm = FileManager.default
            let library = try fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let paths = DDIPaths.default(in: library.appendingPathComponent("StikJIT"))
            let operation = payload["operation"] as? String ?? ""
            if operation == "reset" {
                try StikJIT.resetCachedDDI(at: paths)
                return ["ok": true, "message": "Кэш DDI очищен. Следующая подготовка скачает нужные файлы."]
            }
            guard let pairing = payload["pairing"] as? Data, !pairing.isEmpty else {
                throw failure("Не передан файл сопряжения.")
            }
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
            try pairing.write(to: temp, options: .atomic)
            defer { try? fm.removeItem(at: temp) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if operation == "prepare" {
                switch StikJIT.prepareDevice(pairingFile: temp, paths: paths) {
                case .ready(let security):
                    return ["ok": true, "message": "Устройство подготовлено. TXM: \(security.isTXMPresent.map { $0 ? "есть" : "нет" } ?? "неизвестно"). Можно нажать Play."]
                case .unreachable(let reason), .preparationFailed(let reason):
                    throw failure(reason)
                }
            }
            guard operation == "enable", let pid = payload["pid"] as? NSNumber,
                  pid.int32Value > 0, let script = payload["script"] as? Data, !script.isEmpty else {
                throw failure("Некорректный запрос запуска JIT.")
            }
            // Keep Amethyst's existing UniversalJIT26 + JVM extension protocol.
            // This call stays on this queue until the app's debugger detaches.
            try StikJIT.enableJIT(targetPID: pid.int32Value, pairingFile: temp,
                                 ddiPaths: paths, script: .customBase64(script.base64EncodedString()),
                                 forceScript: payload["forceScript"] as? Bool ?? false)
            return ["ok": true, "message": "JIT включён."]
        } catch {
            return ["ok": false, "message": error.localizedDescription]
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AMJITHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
