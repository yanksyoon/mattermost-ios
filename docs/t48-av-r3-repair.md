# T48-AV-R3 — the follow answer comes from the server, not from a key the server never sends

Card `t_b28e8cfc` (repair of T48-AV §F3, audit task `t_531f894e`). Measured on the pinned 9.11.19
fixture (`http://127.0.0.1:8065`, team `perf`, channel `t36-threads`).

## What was wrong

`PostOptionsViewModel.facts` derived the sheet's follow state from `row.post.isFollowing`. `MMPost`
decodes `is_following` with a `false` default, and 9.11.19 **never sends that key on any surface**, so
the value was `false` on every row of every launch. The only thing that could flip the menu was
`thread_follow_changed` (another client) or this device's own write, both held in the in-memory
`followStates` dictionary. After a relaunch the sheet therefore offered **Follow Message** on threads
the reader already follows, and never offered **Unfollow Message**.

## The probe — where the answer actually is

`scripts/t48_follow_probe.py` (log `build/logs/t48r3-follow-probe.log`). A root + one reply created
as the second fixture account; ask every candidate surface before the follow, after `PUT
…/threads/{root}/following`, and after `DELETE …/threads/{root}/following`:

```
[never_followed] thread_endpoint {"http": 404, "has_is_following": false}
                 threads_list    {"found": false}
                 channel_page_root / get_post {"has_is_following": false}
[after_follow]   thread_endpoint {"http": 200, "has_is_following": false,
                                  "keys": ["delete_at","id","is_urgent","last_reply_at",
                                           "last_viewed_at","participants","post","reply_count",
                                           "unread_mentions","unread_replies"]}
                 threads_list    {"found": true}
[after_unfollow] thread_endpoint {"http": 404}
                 threads_list    {"found": false}
[verdict] {"is_following_key_anywhere": false,
           "thread_endpoint_answers": {"after_follow": 200, "after_unfollow": 404,
                                       "never_followed": 404},
           "threads_list_membership": {"after_follow": true, "after_unfollow": false,
                                       "never_followed": false}}
```

So: **the CRT per-thread endpoint is the read.** `GET /users/me/teams/{team}/threads/{root}` is 200
while the thread is followed and 404 once it is not; the team threads list is the same fact in list
form, and no surface carries a field. The client uses the endpoint (one request per sheet open, ~90 ms
on the fixture) rather than the list (a page of 60 rows to answer one question).

`[other_account_after_unfollow]` is the author's view of the same thread: 200, because a thread's
author is a member of it — which is the same rule, "membership is following".

## The repair

| file | change |
| --- | --- |
| `Mattermost/UI/Native/Channel/PostOptionsService.swift` | `PostOptionsServing.isFollowing(teamID:rootID:) async throws -> Bool?`; the session implementation reads `APIClient.followedThread` (the 404 → `nil` mapping already existed in T36). `nil` = not answered. |
| `Mattermost/UI/Native/Channel/PostOptionsViewModel.swift` | `followReads` (the server's answers) kept apart from `followStates` (writes and socket frames); `loadFollowState(rootID:)` reads once per sheet open with a per-root epoch so a read that was in flight cannot undo a newer write; `applyFollowPatch` is now the single place a local/socket answer lands. |
| `Mattermost/UI/Native/Channel/PostOptionsModels.swift` | `ThreadFollowDerivation.state(socketPatched:serverRead:)` — the row's `is_following` is no longer an input at all. `nil` means the Follow row is **absent**, never "not following". |
| `Mattermost/UI/Native/Channel/PostRowView.swift` | `PostOptionsSheet` reads the answer in `.task(id: rowID)` when it opens, for a channel-surface root that has replies. |

Degradation: a failed read leaves the root unanswered and the sheet draws neither direction — the same
closed direction `PostOptionsCapabilities` already uses for permissions and the team name. It never
claims "not following" on the strength of a failure.

## Proof

Unit (`MattermostTests/T48PostOptionsTests`): `testAFollowedRootOffersUnfollowFromTheServerEvenWithAStaleRowFlag`
(row flag still `false`, server says followed → `unfollowThread` offered),
`testUnfollowingTurnsTheRowBackIntoFollowThread`, `testAStaleFollowReadCannotUndoANewerWrite`,
`testAFailedFollowReadOffersNeitherDirection`, `testTheFollowDerivationPrefersTheNewerPatchAndAnswersNothingWithoutOne`.

Live (`MattermostUITests/T48PostOptionsUITests`):
`testAFollowedRootStillOffersUnfollowAfterARelaunch` — follows the root through the API, opens the
menu, `terminate()` + `launch()`, opens it again, asserts Unfollow (and not Follow) from the drawer,
taps Unfollow, asserts the server's `GET …/threads/{root}` becomes 404, reopens and asserts Follow.

Run lines and the numbers are in the completion record for `t_b28e8cfc`.

## Not measured / out of scope

* A real device and a parity soak: not available on this host.
* The thread pane's own bell (`ThreadView`) was already reading `GET …/threads/{id}` and is untouched.
* The channel page's reply line still keeps `MMPost.isFollowing` in memory for its own badge; the
  menu no longer reads it. Removing the field from `MMPost` is not this card's business.
