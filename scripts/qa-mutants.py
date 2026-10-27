#!/usr/bin/env python3
"""Apply one product defect at a time and record which converted tests it reds.

Every test converted by t_00fb623c must fail under at least one product mutation, or the wait it
now has is not a test of anything (kanban t_00fb623c, acceptance 2). This harness is the pattern
t_eccd49eb used for SocketClientTests: edit -> run the class -> revert, one mutant at a time.

Each edit is an exact `find` -> `replace` on a product file; a `find` that does not appear exactly
once aborts the run instead of silently mutating something else. The tree is reverted in a
`finally`, so an interrupted run leaves no mutant behind.

  python3 build/mutants/run_mutants.py --ids MS1,MCP1       # a subset
  python3 build/mutants/run_mutants.py --all               # every mutant

Writes `build/logs/mut-<id>.log` per mutant and appends a table row to
`docs/t_00fb623c-mutations-2026-10-27.log` when `--log` is given.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SIM = "81A7F251-8B31-4945-8783-5A264C14B8D5"
DERIVED = "~/Library/Developer/Xcode/DerivedData/t-00fb623c"
LOG = REPO / "docs" / "t_00fb623c-mutations-2026-10-27.log"

# (id, note, [test classes], [tests that must red], [(path, find, replace), ...])
MUTANTS: list[tuple[str, str, list[str], list[str], list[tuple[str, str, str]]]] = []


def mutant(mid, note, classes, must_red, edits):
    MUTANTS.append((mid, note, classes if isinstance(classes, list) else [classes],
                    must_red if isinstance(must_red, list) else [must_red], edits))


# ---------------------------------------------------------------- the socket
mutant("MS1-binary-frame-dropped",
       "sendBinaryFrame encodes but never writes: a binary action silently reaches nothing",
       "T44DSocketBinarySendTests",
       ["testBinaryFrameReachesTheTransportThatImplementsSendData"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "        try await transport.send(data: frame)\n        MMLog.debug(\"MMSocket\", \"sent binary frame",
         "        _ = frame\n        MMLog.debug(\"MMSocket\", \"sent binary frame")])

mutant("MS2-binary-error-swallowed",
       "a transport with no binary path is answered with a silent no-op instead of a loud throw",
       "T44DSocketBinarySendTests",
       ["testTextOnlyTransportStillFailsLoudly"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "        try await transport.send(data: frame)\n",
         "        try? await transport.send(data: frame)\n")])

mutant("MS3-socket-never-authenticates",
       "the socket opens and never writes the authentication challenge, so the token reaches no frame",
       "TokenLoggingTests",
       ["testSocketAuthenticationFrameCarriesTheTokenButNoLogLineDoes"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "        if let token = configuration.token, !token.isEmpty {\n            await send(action: \"authentication_challenge\", data: [\"token\": token])\n        }",
         "        if let token = configuration.token, !token.isEmpty {\n            _ = token\n        }")])

mutant("MS4-no-resync-on-reconnect",
       "a reconnect opens the socket and never asks anyone to refetch",
       "T34SocketResyncTests",
       ["testAPostMadeWhileTheSocketWasDownAppearsAfterTheReconnect"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "            await resync?(.reconnected)\n",
         "            _ = resync\n")])

mutant("MS5-watchdog-without-visibility",
       "the delivery watchdog starts even when the caller cannot answer 'is a surface visible?'",
       "T34SocketStallWatchdogTests",
       ["testAClientWithoutAVisibilityPredicateNeverStartsWithAWatchdog"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "        guard let watchdog = configuration.stallWatchdog,\n              isSurfaceVisible != nil,\n",
         "        guard let watchdog = configuration.stallWatchdog,\n")])

mutant("MS6-watchdog-ignores-visibility",
       "silence on a backgrounded app is treated as a delivery gap and refetched",
       "T34SocketStallWatchdogTests",
       ["testAQuietSocketWithNothingOnScreenDoesNotRefetch"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "        guard await isSurfaceVisible() else { return true }\n",
         "")])

mutant("MS7-watchdog-window-not-restarted",
       "a reconnect does not restart the watchdog window, so the old silence fires again at once",
       "T34SocketStallWatchdogTests",
       ["testAReconnectDoesNotDoubleFireAndRestartsTheWatchdogsWindow"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "        lastServerEventAt = now()\n        stallQuietMultiplier = 1\n        MMLog.debug(\"MMSocket\", \"socket open\")",
         "        stallQuietMultiplier = 1\n        MMLog.debug(\"MMSocket\", \"socket open\")")])

mutant("MS8-delivery-does-not-reset-silence",
       "an event that arrives does not count as delivery, so a busy socket looks silent",
       "T34SocketStallWatchdogTests",
       ["testASocketThatKeepsDeliveringIsNeverTreatedAsStalled"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "        lastServerEventAt = now()\n        stallQuietMultiplier = 1\n        for continuation in subscribers.values",
         "        stallQuietMultiplier = 1\n        for continuation in subscribers.values")])

# ---------------------------------------------------------------- the rail's liveness
mutant("ML1-live-at-stream-creation",
       "the rail reports the socket live as soon as the stream object exists (the T43-R defect)",
       "T43RSocketLivenessTests",
       ["testAStreamIsNotALiveSocket"],
       [("Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift",
         "            var reportedLive = false\n            for await event in stream {",
         "            self?.onSocketStateChange?(server.id, true)\n            var reportedLive = false\n            for await event in stream {")])

mutant("ML2-live-on-every-event",
       "every event re-reports liveness, so a second event is counted twice",
       "T43RSocketLivenessTests",
       ["testASecondEventDoesNotReportLivenessTwice"],
       [("Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift",
         "                if !reportedLive {\n                    reportedLive = true\n                    self.onSocketStateChange?(server.id, true)\n                }",
         "                reportedLive = true\n                self.onSocketStateChange?(server.id, true)")])

mutant("ML3-liveness-never-withdrawn",
       "a finished pump leaves the server marked live, so the read-out keeps promising a socket",
       "T43RSocketLivenessTests",
       ["testAFinishedPumpWithdrawsLiveness"],
       [("Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift",
         "        onSocketStateChange?(serverID, false)\n    }\n\n    private func handle(_ event: SocketEvent, serverID: UUID) async {",
         "        _ = serverID\n    }\n\n    private func handle(_ event: SocketEvent, serverID: UUID) async {")])

# ---------------------------------------------------------------- the rail's scopes
mutant("MT1-slow-load-wins",
       "the rail's load has no generation guard, so a slow answer overwrites a newer switch",
       "T32TeamSidebarTests",
       ["testASlowLoadCannotOverwriteANewerOne"],
       [("Mattermost/UI/Native/Sidebar/TeamSwitchViewModel.swift",
         "            let next = try await service.load()\n            guard mine == generation else { return }",
         "            let next = try await service.load()")])

mutant("MT2-post-activity-does-not-refresh",
       "a socket post does not refetch the rail's counters, so a badge never moves",
       "T32TeamSidebarTests",
       ["testPostActivityRefreshesTheTeamsCounters"],
       [("Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift",
         "            scheduleUnreadRefresh(serverID: serverID)\n        default:",
         "            _ = serverID\n        default:")])

mutant("MT3-scope-accepts-everything",
       "the scope stops filtering: every team's events reach the surface that is on screen",
       "T32TeamSidebarTests",
       ["testAfterASwitchThePreviousTeamsEventsAreRefused"],
       [("Mattermost/UI/Native/Sidebar/TeamSocketScope.swift",
         "        guard let teamID, !teamID.isEmpty else { return true }",
         "        guard let teamID, !teamID.isEmpty else { return true }\n        return true")])

mutant("MT4-socket-survives-sign-out",
       "sign-out forgets the rail but never closes the server's socket",
       "T32TeamSidebarTests",
       ["testSignOutClosesTheSocketAndForgetsTheRail"],
       [("Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift",
         "        onSocketStateChange?(serverID, false)\n        await events.close(serverID: serverID)",
         "        onSocketStateChange?(serverID, false)")])

mutant("MT5-reaction-refused",
       "reactions are refused by the scope again (the T37-AV F1 defect): no pill can ever draw",
       "T37SocketReactionRoutingTests",
       ["testASocketReactionReachesTheOpenPanesRowThroughTheRail"],
       [("Mattermost/UI/Native/Sidebar/TeamSocketScope.swift",
         "            return reaction.channelId.isEmpty || isInActiveTeam(channelID: reaction.channelId)",
         "            return false")])

mutant("MT6-reaction-only-on-the-open-channel",
       "a reaction is admitted only for the open channel, so the thread pane's server gets none",
       "T37SocketReactionRoutingTests",
       ["testTheSameGateAdmitsAReactionForTheThreadPanesServer"],
       [("Mattermost/UI/Native/Sidebar/TeamSocketScope.swift",
         "        if let activeChannelID, channelID == activeChannelID { return true }\n        return channelTeams[channelID] == teamID",
         "        return activeChannelID == channelID")])

# ---------------------------------------------------------------- auth
mutant("MA1-expiry-keeps-the-cookie",
       "the webview cookie survives an expiry, so the pane escape hatch is still signed in",
       "T31AuthCoordinatorTests",
       ["testA401FromANonRestoreCallClearsBothCopiesBeforeTheBanner"],
       [("Mattermost/UI/Native/Auth/AuthCoordinator.swift",
         "            await self.cookieClearing.clearAuthCookie(for: server.url, serverID: server.id)\n",
         "")])

mutant("MA2-stale-401-raises-a-banner",
       "a 401 for an already signed-out server raises 'your session expired' anyway",
       "T31AuthCoordinatorTests",
       ["testAStale401ReportForASignedOutServerRaisesNoBanner"],
       [("Mattermost/UI/Native/Auth/AuthCoordinator.swift",
         "        guard current.isSignedIn || (current == .unresolved && hadStoredToken) else { return }",
         "        _ = (current, hadStoredToken)")])

# ---------------------------------------------------------------- the list's scroll restore
mutant("MV1-request-does-not-pend",
       "a pending anchor is remembered but never offered to the view",
       "T34ChannelViewRestoreWiringTests",
       ["testTheListTurnsAPendingAnchorIntoARestoreAndConsumesIt"],
       [("Mattermost/UI/Native/Channel/ChannelViewModel.swift",
         "        scrollAnchor = anchor\n        pendingScrollRestore = anchor",
         "        scrollAnchor = anchor")])

mutant("MV2-consume-is-a-noop",
       "the view cannot consume the anchor, so the same restore is applied again and again",
       "T34ChannelViewRestoreWiringTests",
       ["testTheListTurnsAPendingAnchorIntoARestoreAndConsumesIt",
        "testASecondRequestRestoresAgainAfterTheFirstWasConsumed"],
       [("Mattermost/UI/Native/Channel/ChannelViewModel.swift",
         "    func consumeScrollRestore() {\n        pendingScrollRestore = nil\n    }",
         "    func consumeScrollRestore() {\n    }")])

mutant("MV3-report-ignored",
       "the view's restore report is dropped, so nothing can tell a restore ran",
       "T34ChannelViewRestoreWiringTests",
       ["testTheListTurnsAPendingAnchorIntoARestoreAndConsumesIt",
        "testASecondRequestRestoresAgainAfterTheFirstWasConsumed"],
       [("Mattermost/UI/Native/Channel/ChannelViewModel.swift",
         "    func recordScrollRestore(_ report: ScrollRestoreReport) {\n        lastScrollRestore = report\n    }",
         "    func recordScrollRestore(_ report: ScrollRestoreReport) {\n        _ = report\n    }")])

# ---------------------------------------------------------------- the composer
mutant("MCP1-send-while-sending",
       "a second send is admitted while the first is in flight",
       "T35ComposerViewModelTests",
       ["testASecondSendIsRefusedWhileTheFirstIsInFlight"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        guard phase != .sending, !isUploading else { return false }",
         "        guard !isUploading else { return false }")])

mutant("MCP2-mentions-unfiltered",
       "every mentioned user is offered, including people who are not in the channel",
       "T35ComposerViewModelTests",
       ["testMentionsAreFilteredToTheChannelsMembers"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        return suggestions + ComposerMembership.filter(candidates, members: members)",
         "        _ = members\n        return suggestions + candidates")])

mutant("MCP3-member-list-failure-hides-people",
       "a failed member list is treated as 'nobody is a member', so every name disappears",
       "T35ComposerViewModelTests",
       ["testAFailedMemberListDoesNotHideAnyone"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "            (try? await service.channelMembers(channelID: channelID)) ?? .unknown",
         "            (try? await service.channelMembers(channelID: channelID))\n                ?? ComposerMembership.MemberList(ids: [], isComplete: true)")])

mutant("MCP4-stale-answer-applied",
       "a superseded autocomplete answer overwrites the newer term's list",
       "T35ComposerViewModelTests",
       ["testAStaleAutocompleteAnswerIsDropped"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "            let suggestions = await self.candidates(for: trigger)\n            guard !Task.isCancelled, generation == self.autocompleteGeneration else { return }",
         "            let suggestions = await self.candidates(for: trigger)")])

mutant("MCP5-channel-insertion-without-tilde",
       "a picked channel is inserted without the `~` the server needs to link it",
       "T35ComposerViewModelTests",
       ["testChannelsComeFromTheTeamSearchAndInsertATilde"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "                                   insertion: channelInsertion(channel.name),",
         "                                   insertion: channel.name,")])

mutant("MCP6-custom-emoji-dropped",
       "the server's own emoji catalogue is ignored, so `:` only offers the built-in table",
       "T35ComposerViewModelTests",
       ["testEmojiComeFromTheBuiltInTableAndTheServersCatalogue"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        let customNames: [String] = emojiCatalogue.map { Array($0.identifiers.keys) } ?? []",
         "        let customNames: [String] = []")])

mutant("MCP7-no-draft-write",
       "typing never writes the draft, so a relaunch loses what was typed",
       "T35ComposerViewModelTests",
       ["testTheDraftIsWrittenOnTypingAndRestoredByANewComposer",
        "testEveryKeystrokeIsOnDiskWithoutWaitingForATimer"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        if case .failed = phase { phase = .idle }\n        scheduleDraftSave()\n        refreshTrigger()",
         "        if case .failed = phase { phase = .idle }\n        refreshTrigger()")])

mutant("MCP8-draft-row-survives-a-send",
       "a sent message leaves its draft behind, so the next visit reopens the sent text "
       "(both clears removed: the success path's own delete and the empty-draft write the debounce folds in)",
       "T35ComposerViewModelTests",
       ["testASuccessfulSendClearsTheDraftRow"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        Task { await self.drafts.delete(channelID: self.channelID, rootID: draftRoot) }",
         "        _ = draftRoot"),
        ("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        if draft.isEmpty {\n            await drafts.delete(channelID: channelID, rootID: draftRootID)\n        } else {",
         "        if draft.isEmpty {\n            _ = draftRootID\n        } else {")])

mutant("MCP9-upload-never-completes",
       "a finished upload never becomes `.uploaded`, so the send stays blocked and the id is lost",
       "T35ComposerViewModelTests",
       ["testAnAttachmentUploadsWithProgressFromTheTransport",
        "testAnUploadedAttachmentLetsAnEmptyMessageBeSentAndRidesAlong",
        "testSendIsBlockedWhileAnUploadIsStillInFlight"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        attachments[index].state = .uploaded(fileID: file.id)",
         "        attachments[index].state = .queued")])

mutant("MCP10-fake-progress",
       "the tray reports a made-up fraction instead of the transport's byte count",
       "T35ComposerViewModelTests",
       ["testUploadProgressComesFromTheTransportsByteCount"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "                    let fraction = min(1, max(0, Double(sent) / Double(expected)))",
         "                    let fraction = 0.5")])

mutant("MCP11-retry-forgets-the-bytes",
       "a cancelled upload cannot be retried: the composer drops the bytes it kept for exactly that",
       "T35ComposerViewModelTests",
       ["testCancellingAnUploadReallyStopsItAndOffersRetry"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        uploadData[upload.id] = upload.data\n",
         "")])

mutant("MCP12-remove-keeps-the-row",
       "removing an attachment cancels it but leaves the row in the tray",
       "T35ComposerViewModelTests",
       ["testRemovingAnAttachmentCancelsItAndDropsItFromTheDraft"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "        attachments.removeAll { $0.id == id }\n        scheduleDraftSave()\n    }",
         "        scheduleDraftSave()\n    }")])

mutant("MCP13-failure-not-reported",
       "a failed upload is swallowed: the row keeps spinning and never offers Retry",
       "T35ComposerViewModelTests",
       ["testAFailedUploadIsReportedOnItsRow"],
       [("Mattermost/UI/Native/Composer/ComposerViewModel.swift",
         "                self.setState(.failed(ComposerErrorCopy.message(for: error)), for: upload.id)\n",
         "")])

# ---------------------------------------------------------------- the calls engine
# NOTE: `testAServerReOfferIsAnswered`, `testARemoteCandidateBeforeTheAnswerIsQueuedAndTheCallStillConnects`
# and the third peer-negotiation test are `XCTSkip`ped on this host (a second RTCPeerConnectionFactory
# blocks in CoreAudio), so no mutant can red them here; `testLocalCandidatesAreSentOnlyAfterTheOffer`
# is a bounded observation window on loopback ICE gathering and `testStatisticsReadTheEngineWithoutCrashing`
# is a no-crash smoke test. All four are recorded as exemptions in the log; the other five Calls tests
# red below.
mutant("MC2-deltas-not-folded",
       "participation deltas are not folded into the published call, so the surface reverts them",
       "T44CCallsEngineTests",
       ["testAConfirmedUnmuteSurvivesTheNextSnapshot",
        "testUserJoinedAndLeftMoveTheSessions",
        "testRaisedHandAndHostChangeAreFolded"],
       [("Mattermost/Core/Calls/CallsEngine.swift",
         "            // `snapshot.call` is genuinely authoritative (see `fold(_:)`).\n            fold(event)",
         "            _ = event")])

mutant("MC3-other-channels-deltas-folded",
       "a delta for another channel's call is folded into this one",
       "T44CCallsEngineTests",
       ["testADeltaForAnotherChannelIsNotFolded"],
       [("Mattermost/Core/Calls/CallsEngine.swift",
         "        case let .muteChanged(channelID, userID, sessionID, unmuted):\n            guard channelID == call.channelID else { return }",
         "        case let .muteChanged(channelID, userID, sessionID, unmuted):\n            _ = channelID")])

mutant("MC4-call-end-ignored",
       "call_end leaves the engine marked live",
       "T44CCallsEngineTests",
       ["testCallEndMovesTheEngineToEnded"],
       [("Mattermost/Core/Calls/CallsEngine.swift",
         "            MMLog.info(\"MMCalls\", \"call ended by the server\")\n            snapshot.state = .ended",
         "            MMLog.info(\"MMCalls\", \"call ended by the server\")")])


mutant("MR1-first-connect-refetches",
       "a first connect is treated as a delivery gap: opening the socket refetches the window it just loaded",
       "T34SocketResyncTests",
       ["testAFirstConnectDoesNotRefetchTheWindowAndTheSocketStillDelivers"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "        let isReconnect = hasOpenedOnce\n        hasOpenedOnce = true",
         "        let isReconnect = true\n        hasOpenedOnce = true")])

mutant("MR2-late-resync-handler-ignored",
       "the resync handler is captured when the client is built, so a handler installed afterwards never hears about a reconnect",
       "T34SocketResyncTests",
       ["testAHandlerInstalledAfterTheConnectionStillReceivesTheReconnect"],
       [("Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift",
         "            resync: { [weak self] reason in\n                await self?.socketResynced(serverID: server.id, reason: reason)\n            },",
         "            resync: { [snapshot = self.resyncHandler] _ in\n                await snapshot?(server.id)\n            },")])

mutant("MW1-pong-does-not-answer-the-ping",
       "a pong is not folded into the heartbeat's counter, so a socket that answers every ping is still recycled as dead",
       "T34SocketStallWatchdogTests",
       ["testASilentButPingableSocketRefetchesTheOpenWindow"],
       [("Mattermost/Core/MM/SocketClient.swift",
         "            } else if frame.data?[\"text\"]?.stringValue == \"pong\" {\n                missedPongs = 0\n",
         "            } else if frame.data?[\"text\"]?.stringValue == \"pong\" {\n")])

mutant("MT7-switch-leaves-the-old-scope",
       "a rail tap moves the destination but not the socket scope, so the previous team's events keep being admitted",
       "T32TeamSidebarTests",
       ["testTenRapidSwitchesLeaveOneSubscriptionAndTheLastTeamWins"],
       [("Mattermost/UI/Native/Sidebar/TeamSidebarCoordinator.swift",
         "            .sink { [weak self] location in\n                self?.apply(location)\n            }",
         "            .sink { [weak self] location in\n                _ = location\n            }")])

def apply(edits):
    for rel, find, repl in edits:
        path = REPO / rel
        text = path.read_text()
        count = text.count(find)
        if count != 1:
            raise SystemExit(f"mutation anchor not unique: {rel}: {count} matches for {find!r}")
        path.write_text(text.replace(find, repl))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", default="")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--check", action="store_true", help="only verify the anchors match once, then revert")
    ap.add_argument("--log", action="store_true", help="append rows to docs/t_00fb623c-mutations-*.log")
    args = ap.parse_args()

    wanted = [m for m in MUTANTS if args.all or (args.ids and m[0] in args.ids.split(","))
              or (args.check and not args.ids and not args.all)]
    if args.check:
        wanted = [m for m in MUTANTS]
    if not wanted:
        raise SystemExit("nothing selected")
    if args.check:
        bad = 0
        for mid, _note, _classes, _must, edits in wanted:
            files = sorted({rel for rel, _, _ in edits})
            try:
                apply(edits)
                print(f"{mid}  anchor ok", flush=True)
            except SystemExit as exc:
                print(f"{mid}  ANCHOR MISS: {exc}", flush=True)
                bad += 1
            finally:
                subprocess.run(["git", "checkout", "--", *files], cwd=REPO, check=True)
        print(f"\n{len(wanted) - bad}/{len(wanted)} anchors match")
        return 1 if bad else 0
    rows = []
    for mid, note, classes, must_red, edits in wanted:
        files = sorted({rel for rel, _, _ in edits})
        print(f"\n=== {mid}: {note}", flush=True)
        try:
            apply(edits)
            label = f"mut-{mid}"
            cmd = [sys.executable, str(REPO / "scripts/qa-test.py"),
                   "--sim", f"id={SIM}", "--derived-data", DERIVED, "--label", label, "--"]
            for cls in classes:
                cmd.insert(-1, "--only-testing")
                cmd.insert(-1, f"MattermostTests/{cls}")
            cmd += ["-collect-test-diagnostics", "never"]
            run = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
            log = REPO / "build" / "logs" / f"{label}.log"
            text = log.read_text() if log.exists() else run.stdout + run.stderr
            failed = sorted(set(re.findall(r"Test Case '-\[MattermostTests\.(\w+) (\w+)\]' failed", text)))
            red = sorted({name for _, name in failed})
            missing = [t for t in must_red if t not in red]
            # A build error is not a red test: the mutant never ran, so it proves nothing.
            if "** TEST SUCCEEDED **" not in text and not failed:
                verdict = "BUILD-FAILED"
                print(f"{mid}  {verdict}  see build/logs/{label}.log", flush=True)
            elif not missing:
                verdict = "PASS"
                print(f"{mid}  {verdict}  red={red}", flush=True)
            else:
                verdict = f"MISSING {missing}"
                print(f"{mid}  {verdict}  red={red}", flush=True)
            rows.append((mid, note, classes, must_red, red, verdict))
        finally:
            subprocess.run(["git", "checkout", "--", *files], cwd=REPO, check=True)

    if args.log:
        with LOG.open("a") as fh:
            for mid, note, classes, must_red, red, verdict in rows:
                fh.write(f"### {mid}  {verdict}\n")
                fh.write(f"mutation: {note}\n")
                fh.write(f"target: MattermostTests/{', '.join(classes)}\n")
                fh.write(f"must red: {', '.join(must_red)}\n")
                fh.write(f"red: {', '.join(red) if red else '(none)'}\n\n")
        print(f"\nwrote {LOG.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
