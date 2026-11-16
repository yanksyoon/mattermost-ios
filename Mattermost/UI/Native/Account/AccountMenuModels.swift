// t_9dd73395 — the account menu's rules, as pure functions.
//
// Behaviour reference: mattermost/mattermost master @ `987e5712…`, `webapp/channels/src/components/
// user_account_menu/` (v12.0.1):
//   * `user_account_menu.tsx:46-47` — the two rules the card asks to copy verbatim:
//       `isCustomStatusSet = !isCustomStatusExpired && customStatus && (text.length > 0 || emoji.length > 0)`
//       `shouldConfirmBeforeStatusChange = autoResetPref === '' && status === UserStatuses.OUT_OF_OFFICE`
//   * `user_account_menu.tsx:79-133` — the item order:
//       name → (OOO when set) → set/current custom status → online / away / DND / offline →
//       profile → logout, with a separator between the groups;
//   * `user_account_dnd_menuitem.tsx` — the four status rows share one DND sub-menu
//       (Don't clear / 30 mins / 1 hour / 2 hours / Tomorrow / Choose date and time), and each
//       choice sends `dnd_end_time: endTime.utc().unix()` — **seconds**;
//   * `reset_status_modal.tsx` — the confirmation copy and the preference it writes
//       (`auto_reset_manual_status`, `name` = user id, `value: 'true'` = do not ask again,
//       `'false'` = ask again).
// Licence: Apache-2.0 — behaviour ported with attribution per docs/THIRD_PARTY_NOTICES.md §18; no
// upstream source copied. The decomposition is this repo's own (docs/component-map.md §1).
//
// **Measured on the pinned 9.11.19 server** (`scripts/t_9dd73395_dnd_pref_probe.py`,
// `scripts/t_9dd73395_ooo_probe.py`):
//   * `PUT /users/{id}/status {"status":"ooo"}` → **400** `api.context.invalid_body_param.app_error`
//     (`"out_of_office"` the same). `ooo` is `model.StatusOutOfOffice`; the server sets it itself
//     when automatic replies are enabled, and **no** client route accepts it. So the menu can read
//     and leave Out of office, but cannot enter it — the same set of actions upstream's menu has
//     (its OOO item's click sets `online`).
//   * `dnd_end_time` is echoed verbatim in **seconds**, and `auto_reset_manual_status` round-trips
//     through `PUT /users/{id}/preferences` + `GET /users/{id}/preferences` (name = the user id).
//
// Everything here is pure: no network, no clock (every function that needs "now" takes it).

import Foundation

// MARK: - The menu's items

/// One row of the account menu, in the order the menu draws them.
///
/// A value — not a `Bool` per row — because the card's requirement is the *order*, and an order that
/// only exists as the sequence of `if`s inside a SwiftUI builder cannot be asserted without a UI.
enum AccountMenuItem: Equatable, Sendable {
    /// Avatar + display name + username. Upstream opens the settings modal; here it opens the same
    /// profile screen the "Profile" row does (requirement 6), because this shell's settings sheet is
    /// not the web client's settings modal.
    case name
    /// Out of office: only while the status *is* out of office. Clicking it leaves OOO.
    case outOfOffice
    /// "Set a custom status" — when none is set.
    case setCustomStatus
    /// The custom status that is set, with "Update status".
    case customStatus
    /// The four settable statuses, always in this order.
    case status(UserPresence)
    /// The reader's own profile.
    case profile
    /// Sign out.
    case logout

    /// Whether a separator precedes this row (upstream's `Menu.Separator` placement).
    var startsGroup: Bool {
        switch self {
        case .name, .outOfOffice, .setCustomStatus, .customStatus, .status(.online),
             .profile, .logout:
            return true
        case .status:
            return false
        }
    }

    /// The four statuses, in upstream's order.
    static var statusItems: [AccountMenuItem] { UserPresence.selectable.map { .status($0) } }
}

/// The frozen list the menu draws, from the two facts that decide it.
enum AccountMenuBuilder {

    /// Upstream `user_account_menu.tsx:79-133`, as data.
    ///
    /// - Parameters:
    ///   - presence: my status as the server reports it (`GET /users/{id}/status`).
    ///   - customStatusSet: `AccountMenuRules.isCustomStatusSet(...)` — **not** "a status object
    ///     exists": an expired one is not set (upstream line 46).
    static func items(presence: UserPresence, customStatusSet: Bool) -> [AccountMenuItem] {
        var items: [AccountMenuItem] = [.name]
        if presence == .outOfOffice { items.append(.outOfOffice) }
        items.append(customStatusSet ? .customStatus : .setCustomStatus)
        items.append(contentsOf: AccountMenuItem.statusItems)
        items.append(.profile)
        items.append(.logout)
        return items
    }
}

// MARK: - The rules

enum AccountMenuRules {

    /// The preference that records "do not ask me again" for a manual status
    /// (`Preferences.CATEGORY_AUTO_RESET_MANUAL_STATUS`). The row's `name` is the user's id.
    static let autoResetCategory = "auto_reset_manual_status"

    /// Upstream line 46, verbatim: a custom status is **set** only when it exists, has content in
    /// either field, and has not expired. The expiry check is the half that is easy to drop — and a
    /// dropped one draws a status the server has already retired (`expires_at` in the past), which is
    /// the failing-first case `T9dd73395AccountMenuTests.testAnExpiredCustomStatusIsNotRenderedAsSet`.
    static func isCustomStatusSet(_ status: UserCustomStatus?, now: Date) -> Bool {
        guard let status else { return false }
        guard !status.emoji.isEmpty || !status.text.isEmpty else { return false }
        return !status.isExpired(at: now)
    }

    /// The preference value → the rule upstream's `autoResetPref === ''` expresses.
    ///
    /// - `nil` — the read has not answered (or failed). Treated as **unset** so the confirmation is
    ///   shown: asking is the conservative side, and a failed *read* must not silently turn a
    ///   confirmation off.
    /// - `""` — the row does not exist: unset.
    /// - `"false"` — the reader asked to be asked again.
    /// - `"true"` / anything else — the reader answered; do not ask.
    static func asksBeforeLeavingOutOfOffice(preferenceValue: String?) -> Bool {
        switch (preferenceValue ?? "").lowercased() {
        case "true": return false
        default: return true
        }
    }

    /// Upstream line 47: only Out of office gets the confirmation, and only while the preference
    /// has not been answered.
    static func shouldConfirmBeforeStatusChange(preferenceValue: String?,
                                                status: UserPresence) -> Bool {
        guard status == .outOfOffice else { return false }
        return asksBeforeLeavingOutOfOffice(preferenceValue: preferenceValue)
    }

    /// The value to save when the reader ticks "Do not ask me again": upstream writes `'true'` on
    /// confirm and `'false'` on cancel.
    static func autoResetPreferenceValue(dontAskAgain: Bool) -> String {
        dontAskAgain ? "true" : "false"
    }

    /// The preference row itself (`name` = the user id, as upstream's `reset_status_modal.tsx` does).
    static func autoResetPreference(userID: String, dontAskAgain: Bool) -> MMPreference {
        MMPreference(userId: userID,
                     category: autoResetCategory,
                     name: userID,
                     value: autoResetPreferenceValue(dontAskAgain: dontAskAgain))
    }

    /// The `auto_reset_manual_status` value out of a preference list (`nil` when the row is absent —
    /// which upstream's selector also reports as `''`).
    static func autoResetValue(in preferences: [MMPreference], userID: String) -> String? {
        preferences.first { $0.category == autoResetCategory && $0.name == userID }?.value
    }

    // MARK: The DND sub-menu (upstream `user_account_dnd_menuitem.tsx`)

    /// The fixed end-time choices of the DND sub-menu, in upstream's order.
    ///
    /// A separate vocabulary from `StatusDuration`: upstream's DND menu has **two hours** and
    /// **tomorrow 9:00**, and no "four hours"/"this week" — the custom-status editor's list is the
    /// one `StatusDuration` describes.
    enum DNDChoice: String, CaseIterable, Identifiable, Sendable {
        case doNotClear
        case thirtyMinutes
        case oneHour
        case twoHours
        case tomorrow

        var id: String { rawValue }

        /// The row's label (upstream's `userAccountMenu.dndSubMenuItem.*`).
        var title: String {
            switch self {
            case .doNotClear: return "Don't clear"
            case .thirtyMinutes: return "30 mins"
            case .oneHour: return "1 hour"
            case .twoHours: return "2 hours"
            case .tomorrow: return "Tomorrow"
            }
        }

        /// A stable identifier for a UI test.
        var identifier: String { "accountMenu.dnd.\(rawValue)" }

        /// When this choice ends, from `now` — **seconds** since the epoch, because that is the unit
        /// `dnd_end_time` is in (upstream sends `endTime.utc().unix()`).
        ///
        /// `nil` for "Don't clear": the key is omitted and the server keeps the DND until it is
        /// changed (`moment(0)` in upstream is `dnd_end_time: 0`, the same fact).
        /// `tomorrow` is the next day at **09:00** in `calendar`'s time zone, which is upstream's
        /// `add(1, 'day').set({hour: 9, minute: 0})`.
        func endTimeSeconds(from now: Date, calendar: Calendar = .current) -> Int64? {
            switch self {
            case .doNotClear:
                return nil
            case .thirtyMinutes:
                return Self.seconds(now.addingTimeInterval(30 * 60))
            case .oneHour:
                return Self.seconds(now.addingTimeInterval(60 * 60))
            case .twoHours:
                return Self.seconds(now.addingTimeInterval(2 * 60 * 60))
            case .tomorrow:
                let start = calendar.startOfDay(for: now)
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: start),
                      let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) else {
                    return nil
                }
                return Self.seconds(nine)
            }
        }

        /// The value upstream sends for "Choose date and time" (a one-off picker). Not a row of the
        /// fixed list; the menu opens a date picker for it.
        static let customIdentifier = "accountMenu.dnd.custom"

        private static func seconds(_ date: Date) -> Int64 {
            Int64(date.timeIntervalSince1970.rounded())
        }
    }

    /// Upstream's DND secondary label: what the DND row says underneath its title
    /// (`user_account_dnd_menuitem.tsx` `getSecondaryLabel`).
    ///
    /// "Until {time}" today, "Until tomorrow {time}", "Until {date time}" later, and
    /// "Until indefinitely" when there is no end time. A `dnd` whose end time has passed reports the
    /// plain "Disables all notifications" — the window is over, so "until 3:00 PM" would be a lie.
    static func dndSecondaryLabel(endTime: Date?,
                                  now: Date,
                                  calendar: Calendar = .current,
                                  locale: Locale = .current,
                                  timeZone: TimeZone = .current) -> String {
        guard let endTime else { return "Until indefinitely" }
        guard endTime > now else { return "Disables all notifications" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: endTime)
        if calendar.isDate(endTime, inSameDayAs: now) { return "Until \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(endTime, inSameDayAs: tomorrow) {
            return "Until tomorrow \(time)"
        }
        formatter.dateStyle = .medium
        return "Until \(formatter.string(from: endTime))"
    }

    // MARK: The confirmation copy (upstream `reset_status_modal.tsx`)

    /// The title of the "you are about to leave this status" confirmation:
    /// `Your status is set to "<current>"`.
    static func confirmTitle(current: UserPresence) -> String {
        "Your status is set to \"\(current.title)\""
    }

    /// The message. Leaving Out of office says it also turns automatic replies off — the reason the
    /// confirmation exists at all (upstream's `…auto_responder.message_online`).
    static func confirmMessage(current: UserPresence, new: UserPresence) -> String {
        if current == .outOfOffice {
            return "Would you like to switch your status to \"\(new.title)\" and disable automatic replies?"
        }
        return "Would you like to switch your status to \"\(new.title)\"?"
    }

    /// The confirmation's destructive button: `Set status to "<new>"`.
    static func confirmActionTitle(new: UserPresence) -> String {
        "Set status to \"\(new.title)\""
    }

    /// The confirmation's cancel button: `Stay "<current>"`.
    static func confirmCancelTitle(current: UserPresence) -> String {
        "Stay \"\(current.title)\""
    }
}

// MARK: - The one action with a side effect outside the menu

/// The Sign-out row's action, as a named seam.
///
/// Requirement 7 says the row "reuses `AuthCoordinator.signOut`" and must "still clear the session,
/// cookie and revocation, and land on the sign-in screen". The landing is T31's phase path
/// (`AuthCoordinator.setPhase(.signedOut)` → `NativeShellView.showsAuthSurface` → `AuthSurfaceView`),
/// so what is left to pin here is that the menu calls **exactly** the call Settings calls — and a
/// unit test can run that call with a real `AuthCoordinator` and no UI
/// (`T9dd73395AccountMenuTests.testSignOutFromTheMenuClearsTheSessionTheCookieAndRevokes`).
@MainActor
enum AccountMenuActions {

    /// What the menu's Sign out row does once the confirmation is accepted.
    static func signOut(server: ServerConfig, auth: AuthCoordinator) async {
        // The local clear happens synchronously inside `signOut`'s first half, so the shell's phase
        // is `.signedOut` before the cookie clear and the network revocation finish — a termination in
        // that window cannot leave a usable credential (T31-AV F2).
        await auth.signOut(server)
    }
}
