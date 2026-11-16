import Foundation

/// The local pairing check kaka uses to reach iPhone developer services through 10.7.0.1.
enum PairingBridge {
    struct Failure: LocalizedError {
        let message: String
        let code: String
        var errorDescription: String? { message }
    }

    private final class Box: @unchecked Sendable {
        var continuation: CheckedContinuation<String, Error>?
        init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    }

    static func udid(deviceAddress: String, pairingFile: String, hostName: String) async throws -> String {
        let request: [String: String] = [
            "device_address": deviceAddress,
            "pairing_file": pairingFile,
            "host_name": hostName,
        ]
        let json = try JSONSerialization.data(withJSONObject: request)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let box = Unmanaged.passRetained(Box(continuation))
            let rc = String(decoding: json, as: UTF8.self).withCString { text in
                poki_pairing_check(text, { context, event in
                    guard let context, let event else { return }
                    let unmanaged = Unmanaged<Box>.fromOpaque(context)
                    let box = unmanaged.takeUnretainedValue()
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(String(cString: event).utf8))) as? [String: Any],
                          object["event"] as? String == "result" else { return }
                    if object["ok"] as? Bool == true,
                       let value = object["value"] as? [String: Any],
                       let udid = value["udid"] as? String {
                        box.continuation?.resume(returning: udid)
                    } else {
                        box.continuation?.resume(throwing: Failure(
                            message: object["error"] as? String ?? "The pairing check failed.",
                            code: object["code"] as? String ?? "device"
                        ))
                    }
                    box.continuation = nil
                    unmanaged.release()
                }, box.toOpaque())
            }
            if rc != 0 {
                let box = box.takeRetainedValue()
                box.continuation?.resume(throwing: Failure(message: "The pairing check did not start.", code: "config"))
                box.continuation = nil
            }
        }
    }
}
