// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
// `app/client/rest/error.ts` (`getFullErrorMessage` / the "offline" and "no permission" copy every
// screen shows) and `app/components/common_error/`.
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §13; no
// upstream source copied.
//
// One place maps a transport error onto reader-facing copy. The *mapping* (which MMError case means
// "you are offline" rather than "the server is broken") is the shared rule; the *wording* is the
// screen's, so a channel can say "this channel" where a thread says "this thread" without either
// screen owning a second copy of the switch. Added in T36 when the thread pane needed the same
// answer as T34's channel pane and a second switch would have been the beginning of two.

import Foundation

enum MMErrorCopy {

    /// The reader-facing sentence for `error`.
    ///
    /// - Parameters:
    ///   - offline/timeout/unauthorized/forbidden/notFound/rateLimited: the sentence for that case,
    ///     in the calling screen's own words (a channel says "this channel", a thread "this thread").
    ///   - fallback: used for a case with no sentence of its own (a server error, a transport
    ///     failure with a message, a decode failure).
    static func message(for error: Error,
                        offline: String,
                        timeout: String,
                        unauthorized: String,
                        forbidden: String,
                        notFound: String,
                        rateLimited: String,
                        fallback: String) -> String {
        guard let mm = error as? MMError else { return error.localizedDescription }
        switch mm {
        case .offline: return offline
        case .timeout: return timeout
        case .unauthorized: return unauthorized
        case .forbidden: return forbidden
        case .notFound: return notFound
        case .rateLimited: return rateLimited
        default: break
        }
        return mm.errorDescription ?? fallback
    }
}
