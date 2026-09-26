import Foundation
import SignerAPI

/// LalaSigner: XPC service inside LALA.app. Sandboxed with no network entitlement, it holds the seed
/// in the data-protection Keychain under its own access group, checks every request with the guard and
/// only then signs. The app never sees the seed or a private key.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only code signed by our team may talk to the signer.
        connection.setCodeSigningRequirement("identifier \"app.lala.mac\" and anchor apple generic and certificate leaf[subject.OU] = \"N78L833HCS\"")
        connection.exportedInterface = NSXPCInterface(with: LalaSignerXPC.self)
        connection.exportedObject = SignerService()
        connection.resume()
        return true
    }
}

final class SignerService: NSObject, LalaSignerXPC {
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
