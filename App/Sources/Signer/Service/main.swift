import Foundation
import SignerAPI

/// Signer: XPC service inside ihatecrypto.app. Sandboxed with no network entitlement, it holds the seed
/// in the data-protection Keychain under its own access group, checks every request with the guard and
/// only then signs. The app never sees the seed or a private key.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    static let app = Bundle.main.bundleIdentifier.flatMap { $0.hasSuffix(".signer") ? String($0.dropLast(7)) : nil } ?? "app.ihatecrypto.mac"

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only the app this signer is built into, signed by our team, may talk to it: app.ihatecrypto.mac for
        // app.ihatecrypto.mac.signer; the development copy's signer (….dev.signer) takes only the development copy.
        connection.setCodeSigningRequirement("identifier \"\(Self.app)\" and anchor apple generic and certificate leaf[subject.OU] = \"N78L833HCS\"")
        connection.exportedInterface = NSXPCInterface(with: SignerXPC.self)
        connection.exportedObject = SignerService()
        connection.resume()
        return true
    }
}

final class SignerService: NSObject, SignerXPC {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        var answer: SignerReply
        do { answer = try Signer.handle(try JSONDecoder().decode(SignerRequest.self, from: request)) }
        catch { answer = SignerReply(ok: false, error: error.localizedDescription) }
        reply((try? JSONEncoder().encode(answer)) ?? Data())
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
