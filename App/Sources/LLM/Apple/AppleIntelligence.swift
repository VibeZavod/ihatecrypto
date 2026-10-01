import Foundation
import FoundationModels
import LLMCore
import Security

/// Apple Intelligence through the Foundation Models framework: the model on this Mac, and on macOS 27 the bigger one on
/// Apple's Private Cloud Compute once Apple grants the app its managed entitlement. No key, no sign-in, no bill.
public struct AppleIntelligence: LLMProvider {
    static let onDevice = "apple-on-device", privateCloud = "apple-private-cloud"
    /// Granted by Apple on request (apps under 2M downloads); without it PCC says «available» but every call fails with
    /// ModelManagerError 1046 (checked 2026-09-30 on macOS 27.0).
    static let entitlement = "com.apple.developer.private-cloud-compute"

    public init() {}

    public var info: ProviderInfo { Self.info }

    // ponytail: read once at launch; turning Apple Intelligence on or finishing its download shows after a restart.
    static let info: ProviderInfo = {
        var models: [String] = []
        if hasPrivateCloud { models.append(privateCloud) }
        let local = SystemLanguageModel.default.availability
        if local == .available { models.append(onDevice) }
        return ProviderInfo(
            id: "apple", name: "Apple Intelligence", kind: .local, defaultModel: models.first ?? onDevice,
            note: "Apple's Foundation Models: free, no key. On this Mac the model holds only 4,096 tokens, too small for the chat's "
                + "brief; Private Cloud Compute (32k, on Apple's servers) needs an entitlement Apple grants on request.",
            unavailable: models.isEmpty ? reason(local) : nil,
            models: models
        )
    }()

    static var hasPrivateCloud: Bool {
        guard #available(macOS 27, *), let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool == true else { return false }
        return PrivateCloudComputeLanguageModel().isAvailable
    }

    static func reason(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings, then restart ihatecrypto."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model; restart ihatecrypto when it's done."
        default: "Apple Intelligence isn't available on this Mac."
        }
    }

    public func client(_ credential: Credential?, save: @escaping SaveCredential) throws -> any LLMClient {
        AppleIntelligenceClient()
    }
}

struct AppleIntelligenceClient: LLMClient {
    /// A fresh session per call: the app sends the whole conversation every time, like to any other model.
    func complete(_ r: LLMRequest) async throws -> String {
        let instructions = r.system.isEmpty ? nil : r.system
        let prompt = r.dialogue.map(\.text).joined(separator: "\n\n")
        let session: LanguageModelSession
        if r.model == AppleIntelligence.privateCloud, #available(macOS 27, *) {
            session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
        } else {
            session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        }
        do {
            return try await session.respond(to: prompt).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw LLMError("Apple Intelligence: the request is longer than this model holds. Pick a bigger model for the chat.")
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            throw LLMError("Apple Intelligence declined this request (its safety guardrails).")
        } catch {
            // macOS 27's LanguageModelError already reads well: «Content contains 8058 tokens, which exceeds … 4096.»
            throw LLMError("Apple Intelligence: \(error.localizedDescription)")
        }
    }
}
