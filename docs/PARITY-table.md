# Parity — generated from parity/ (do not edit by hand)

`python3 parity/generate.py --render-md` writes this file. A hand edit is a `--check` failure,
same as `parity/out/*`. The machine record is `parity/*.tsv` + `parity/verdicts.json`.

## accessibility

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| accessibility | accessibility | - | partial | MattermostTests/T45A11yTests.swift::testEveryRoleHasATextStyleAndAPlausibleDefaultSize | - |

## apps

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| apps | apps | GET /plugins/com.mattermost.apps/api/v1/bindings@v4 | no | - | - |
| apps | apps | POST /plugins/com.mattermost.apps/api/v1/call@v4 | no | - | - |

## apps_form

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| apps_form | apps_form | app/screens/apps_form@v2.45.0 | no | - | docs/t_61525849-s34-apps-forms-decision.md §5 D2 |

## attachment_options

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| attachment_options | attachment_options | app/screens/attachment_options@v2.45.0 | no | - | - |

## boards

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| boards | boards | app/products/boards@v2.45.0 | partial | MattermostTests/T46WebFallbackTests.swift::testTheFixedRowsAddressExactlyTheWebAppsOwnRoutes | - |

## bottom_sheet

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| bottom_sheet | bottom_sheet | app/screens/bottom_sheet@v2.45.0 | no | - | - |

## browse_channels

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| browse_channels | browse_channels | app/screens/browse_channels@v2.45.0 | partial | MattermostTests/T40ChannelInfoTests.swift::testAdminPermissionsOfferEveryActionOnAPublicChannel | - |

## calls

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| calls | calls | app/products/calls@v2.45.0 | partial | MattermostTests/T44DCallsSurfaceTests.swift::testParticipantRowsSurviveMissingProfilesAndMarkTheReader | - |

## categories

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| categories | categories | GET /users/{user_id}/teams/{team_id}/channels/categories@v4 | no | - | - |
| categories | categories | GET /users/{user_id}/teams/{team_id}/channels/categories/order@v4 | no | - | - |
| categories | categories | GET /users/{user_id}/teams/{team_id}/channels/categories/{category_id}@v4 | no | - | - |
| categories | categories | PUT /users/{user_id}/teams/{team_id}/channels/categories@v4 | no | - | - |

## channel

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel | channel | app/components/post_list@v2.45.0 | partial | MattermostTests/T34PostListTests.swift::testItemsAreOldestFirstEvenWhenGivenNewestFirst | - |
| channel | channel | app/screens/channel@v2.45.0 | partial | MattermostTests/T34ChannelViewModelTests.swift::testFirstPageLoadsNewestFirstAndRendersOldestFirst | - |

## channel_add_members

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel_add_members | channel_add_members | app/screens/channel_add_members@v2.45.0 | no | - | - |

## channel_bookmark

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel_bookmark | channel_bookmark | app/screens/channel_bookmark@v2.45.0 | partial | MattermostTests/T05ChannelBookmarksTests.swift::testTheServersSortOrderIsTheDrawOrder | - |
| channel_bookmark | channel_bookmark | GET /channels/{channel_id}/bookmarks@v4 | no | - | - |
| channel_bookmark | channel_bookmark | POST /channels/{channel_id}/bookmarks/{bookmark_id}/sort_order@v4 | no | - | - |

## channel_configuration

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel_configuration | channel_configuration | app/screens/channel_configuration@v2.45.0 | no | - | - |

## channel_files

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel_files | channel_files | app/screens/channel_files@v2.45.0 | no | - | - |

## channel_info

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel_info | channel_info | app/screens/channel_info@v2.45.0 | partial | MattermostTests/T52ChannelInfoCompletenessTests.swift::testLevelVocabularyIsTheServersOwnStrings | - |

## channel_notification_preferences

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel_notification_preferences | channel_notification_preferences | app/screens/channel_notification_preferences@v2.45.0 | no | - | - |

## channel_settings

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel_settings | channel_settings | app/screens/channel_settings@v2.45.0 | no | - | - |

## channel_share

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channel_share | channel_share | app/screens/channel_share@v2.45.0 | no | - | - |

## channels

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| channels | channels | DELETE /channels/{channel_id}@v4 | no | - | - |
| channels | channels | DELETE /channels/{channel_id}/members/{user_id}@v4 | no | - | - |
| channels | channels | GET /channels@v4 | no | - | - |
| channels | channels | GET /channels/{channel_id}/access_control/attributes@v4 | no | - | - |
| channels | channels | GET /channels/{channel_id}/common_teams@v4 | no | - | - |
| channels | channels | GET /channels/{channel_id}/members@v4 | no | - | - |
| channels | channels | GET /channels/{channel_id}/members/{user_id}@v4 | no | - | - |
| channels | channels | GET /channels/{channel_id}/stats@v4 | no | - | - |
| channels | channels | GET /channels/{channel_id}/timezones@v4 | no | - | - |
| channels | channels | GET /remotecluster@v4 | no | - | - |
| channels | channels | GET /sharedchannels@v4 | no | - | - |
| channels | channels | GET /sharedchannels/{channel_id}/remotes@v4 | no | - | - |
| channels | channels | GET /teams/{team_id}/channels/autocomplete@v4 | no | - | - |
| channels | channels | GET /teams/{team_id}/channels/managed_categories@v4 | no | - | - |
| channels | channels | GET /teams/{team_id}/channels/search_autocomplete@v4 | no | - | - |
| channels | channels | GET /users/{user_id}/channel_members@v4 | no | - | - |
| channels | channels | GET /users/{user_id}/channels@v4 | no | - | - |
| channels | channels | GET /users/{user_id}/teams@v4 | no | - | - |
| channels | channels | POST /channels@v4 | no | - | - |
| channels | channels | POST /channels/direct@v4 | no | - | - |
| channels | channels | POST /channels/group@v4 | no | - | - |
| channels | channels | POST /channels/members/me/view@v4 | no | - | - |
| channels | channels | POST /channels/search@v4 | no | - | - |
| channels | channels | POST /channels/{channel_id}/convert_to_channel@v4 | no | - | - |
| channels | channels | POST /channels/{channel_id}/members@v4 | no | - | - |
| channels | channels | POST /channels/{channel_id}/members/ids@v4 | no | - | - |
| channels | channels | POST /channels/{channel_id}/restore@v4 | no | - | - |
| channels | channels | POST /remotecluster/{remote_id}/channels/{channel_id}/invite@v4 | no | - | - |
| channels | channels | POST /remotecluster/{remote_id}/channels/{channel_id}/uninvite@v4 | no | - | - |
| channels | channels | POST /teams/{team_id}/channels/search@v4 | no | - | - |
| channels | channels | POST /teams/{team_id}/channels/search_archived@v4 | no | - | - |
| channels | channels | PUT /channels/{channel_id}@v4 | no | - | - |
| channels | channels | PUT /channels/{channel_id}/members@v4 | no | - | - |
| channels | channels | PUT /channels/{channel_id}/members/{user_id}/autotranslation@v4 | no | - | - |
| channels | channels | PUT /channels/{channel_id}/members/{user_id}/notify_props@v4 | no | - | - |
| channels | channels | PUT /channels/{channel_id}/patch@v4 | no | - | - |
| channels | channels | PUT /channels/{channel_id}/privacy@v4 | no | - | - |

## code

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| code | code | app/screens/code@v2.45.0 | no | - | - |

## component_library

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| component_library | component_library | app/screens/component_library@v2.45.0 | no | - | - |

## composer

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| composer | composer | app/components/autocomplete@v2.45.0 | partial | MattermostTests/T35ComposerModelsTests.swift::testAMentionIsTheWordBeforeTheCaret | - |
| composer | composer | app/components/post_draft@v2.45.0 | partial | MattermostTests/T35ComposerModelsTests.swift::testAMentionIsTheWordBeforeTheCaret | - |

## convert_gm_to_channel

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| convert_gm_to_channel | convert_gm_to_channel | app/screens/convert_gm_to_channel@v2.45.0 | no | - | - |

## create_direct_message

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| create_direct_message | create_direct_message | app/screens/create_direct_message@v2.45.0 | no | - | - |

## create_or_edit_channel

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| create_or_edit_channel | create_or_edit_channel | app/screens/create_or_edit_channel@v2.45.0 | yes | MattermostTests/T47CreateChannelTests.swift::testTheRuleAcceptsLowercaseDigitsHyphenAndUnderscore | t_e1ddfba4 |

## custom_profile_attributes

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| custom_profile_attributes | custom_profile_attributes | GET /custom_profile_attributes/fields@v4 | no | - | - |
| custom_profile_attributes | custom_profile_attributes | GET /users/{user_id}/custom_profile_attributes@v4 | no | - | - |
| custom_profile_attributes | custom_profile_attributes | PATCH /custom_profile_attributes/values@v4 | no | - | - |

## custom_status

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| custom_status | custom_status | app/screens/custom_status@v2.45.0 | no | - | - |

## custom_status_clear_after

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| custom_status_clear_after | custom_status_clear_after | app/screens/custom_status_clear_after@v2.45.0 | no | - | - |

## data_erased

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| data_erased | data_erased | app/screens/data_erased@v2.45.0 | no | - | - |

## deep-link

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| deep-link | deep-link | - | partial | MattermostTests/DeepLinkRouterTests.swift::testParsesMattermostScheme | - |

## diagnostics

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| diagnostics | diagnostics | - | partial | MattermostTests/DiagnosticsTests.swift::testStepEnumerationMatchesDesktopStepSet | - |

## dialog_router

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| dialog_router | dialog_router | app/screens/dialog_router@v2.45.0 | no | - | t_e14483c8 |

## draft_scheduled_post_options

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| draft_scheduled_post_options | draft_scheduled_post_options | app/screens/draft_scheduled_post_options@v2.45.0 | no | - | - |

## edit_post

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| edit_post | edit_post | app/screens/edit_post@v2.45.0 | partial | MattermostTests/T35ComposerModelsTests.swift::testAMentionIsTheWordBeforeTheCaret | - |

## edit_profile

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| edit_profile | edit_profile | app/screens/edit_profile@v2.45.0 | partial | MattermostTests/T50EditProfileTests.swift::testPatchCarriesOnlyTheFieldsThatChanged | - |

## edit_server

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| edit_server | edit_server | app/screens/edit_server@v2.45.0 | no | - | - |

## emoji_picker

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| emoji_picker | emoji_picker | app/screens/emoji_picker@v2.45.0 | partial | MattermostTests/EmojiShortcodeTableTests.swift::testTheBundledTableIsCompleteAndNotDegraded | - |

## emojis

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| emojis | emojis | GET /emoji@v4 | no | - | - |
| emojis | emojis | GET /emoji/autocomplete@v4 | no | - | - |
| emojis | emojis | GET /emoji/name@v4 | no | - | - |
| emojis | emojis | POST /emoji/search@v4 | no | - | - |

## files

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| files | files | GET /files/{file_id}/info@v4 | no | - | - |
| files | files | GET /files/{file_id}/link@v4 | no | - | - |

## find_channels

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| find_channels | find_channels | app/screens/find_channels@v2.45.0 | partial | MattermostTests/T40ChannelInfoTests.swift::testPlainMemberIsOfferedOnlyTheMemberList | - |

## forgot_password

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| forgot_password | forgot_password | app/screens/forgot_password@v2.45.0 | partial | MattermostTests/T49TermsOfServiceTests.swift::testPasswordResetPostsTheEmailToTheServersEndpoint | - |

## gallery

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| gallery | gallery | app/screens/gallery@v2.45.0 | partial | MattermostTests/T38AttachmentTests.swift::testAPNGIsAnImageAndItsTypeLabelNamesTheFormat | - |

## general

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| general | general | GET /data_retention/policy@v4 | no | - | - |
| general | general | GET /system/timezones@v4 | no | - | - |
| general | general | GET /users/{user_id}/data_retention/channel_policies@v4 | no | - | - |
| general | general | GET /users/{user_id}/data_retention/team_policies@v4 | no | - | - |
| general | general | POST /roles/names@v4 | no | - | - |

## global_drafts

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| global_drafts | global_drafts | app/screens/global_drafts@v2.45.0 | partial | MattermostTests/T51GlobalDraftsTests.swift::testASnippetCollapsesEveryKindOfWhitespace | - |

## global_threads

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| global_threads | global_threads | app/screens/global_threads@v2.45.0 | partial | MattermostTests/T36GlobalThreadsViewModelTests.swift::testLoadShowsTheNewestThreadFirstAndTheServersCounters | - |

## home

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| home | home | app/screens/home@v2.45.0 | partial | MattermostTests/T33-ChannelSidebarTests.swift::testCategoryDecodesTheServersShape | - |

## in_app_notification

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| in_app_notification | in_app_notification | app/screens/in_app_notification@v2.45.0 | no | - | - |

## integration_selector

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| integration_selector | integration_selector | app/screens/integration_selector@v2.45.0 | no | - | - |

## integrations

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| integrations | integrations | GET /commands@v4 | no | - | - |
| integrations | integrations | GET /teams/{team_id}/commands/autocomplete@v4 | no | - | - |
| integrations | integrations | GET /teams/{team_id}/commands/autocomplete_suggestions@v4 | no | - | - |
| integrations | integrations | POST /commands@v4 | no | - | - |
| integrations | integrations | POST /commands/execute@v4 | no | - | - |

## invite

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| invite | invite | app/screens/invite@v2.45.0 | no | - | - |

## join_team

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| join_team | join_team | app/screens/join_team@v2.45.0 | no | - | - |

## latex

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| latex | latex | app/screens/latex@v2.45.0 | no | - | - |

## login

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| login | login | app/screens/login@v2.45.0 | partial | MattermostTests/T31-AuthTests.swift::testSubmitIsDisabledUntilBothFieldsCarrySomething | - |

## manage_channel_members

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| manage_channel_members | manage_channel_members | app/screens/manage_channel_members@v2.45.0 | partial | MattermostTests/T40ChannelInfoTests.swift::testPlainMemberIsOfferedOnlyTheMemberList | - |

## mentions

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| mentions | mentions | app/screens/mentions@v2.45.0 | partial | MattermostTests/T42ActivityTests.swift::testKeysAreUpstreamsOrderAndShape | - |

## mfa

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| mfa | mfa | app/screens/mfa@v2.45.0 | partial | MattermostTests/T31-AuthTests.swift::testMFARequiredMovesToTheSecondStepAndVerifiesWithTheSameCredential | - |

## mm_blocks_content

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| mm_blocks_content | mm_blocks_content | app/screens/mm_blocks_content@v2.45.0 | no | - | - |

## notification

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| notification | notification | - | partial | MattermostTests/T43NotificationInputTests.swift::testANativePaneMakesTheSocketTheInput | - |

## nps

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| nps | nps | POST /plugins/{plugin_id}/api/v1/give_feedback@v4 | no | - | - |

## onboarding

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| onboarding | onboarding | app/screens/onboarding@v2.45.0 | partial | MattermostTests/WelcomeViewTests.swift::testStartsAtRequestedIndex | - |

## parity

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| parity | parity | - | partial | - | t_e56d2589 |

## pdf_viewer

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| pdf_viewer | pdf_viewer | app/screens/pdf_viewer@v2.45.0 | no | - | - |

## permalink

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| permalink | permalink | app/screens/permalink@v2.45.0 | partial | MattermostTests/DeepLinkRouterTests.swift::testParsesMattermostScheme | - |

## pinned_messages

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| pinned_messages | pinned_messages | app/screens/pinned_messages@v2.45.0 | partial | MattermostTests/T39SearchTests.swift::testEachDocumentedModifierIsParsedComposedAndSentVerbatim | - |

## playbooks

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| playbooks | playbooks | app/products/playbooks@v2.45.0 | partial | MattermostTests/T46WebFallbackTests.swift::testTheFixedRowsAddressExactlyTheWebAppsOwnRoutes | - |

## plugins

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| plugins | plugins | GET /plugins/webapp@v4 | no | - | - |

## post_options

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| post_options | post_options | app/screens/post_options@v2.45.0 | partial | MattermostTests/T48PostOptionsTests.swift::testTheOrderIsUpstreamsRenderOrder | - |

## post_priority_picker

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| post_priority_picker | post_priority_picker | app/screens/post_priority_picker@v2.45.0 | no | - | - |

## posts

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| posts | posts | DELETE /posts/{post_id}@v4 | no | - | - |
| posts | posts | DELETE /posts/{post_id}/burn@v4 | no | - | - |
| posts | posts | DELETE /users/{user_id}/posts@v4 | no | - | - |
| posts | posts | GET /channels/{channel_id}/pinned@v4 | no | - | - |
| posts | posts | GET /channels/{channel_id}/posts@v4 | no | - | - |
| posts | posts | GET /posts/{post_id}@v4 | no | - | - |
| posts | posts | GET /posts/{post_id}/files/info@v4 | no | - | - |
| posts | posts | GET /posts/{post_id}/info@v4 | no | - | - |
| posts | posts | GET /posts/{post_id}/reactions@v4 | no | - | - |
| posts | posts | GET /posts/{post_id}/reveal@v4 | no | - | - |
| posts | posts | GET /posts/{post_id}/thread@v4 | no | - | - |
| posts | posts | GET /users/{user_id}/posts/flagged@v4 | no | - | - |
| posts | posts | POST /posts@v4 | no | - | - |
| posts | posts | POST /posts/{post_id}/actions@v4 | no | - | - |
| posts | posts | POST /posts/{post_id}/pin@v4 | no | - | - |
| posts | posts | POST /posts/{post_id}/unpin@v4 | no | - | - |
| posts | posts | POST /reactions@v4 | no | - | - |
| posts | posts | POST /users/{user_id}/posts@v4 | no | - | - |
| posts | posts | PUT /posts/{post_id}@v4 | no | - | - |
| posts | posts | PUT /posts/{post_id}/patch@v4 | no | - | - |

## preferences

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| preferences | preferences | GET /users/{user_id}/preferences@v4 | no | - | - |
| preferences | preferences | POST /users/{user_id}/preferences/delete@v4 | no | - | - |
| preferences | preferences | PUT /users/{user_id}/preferences@v4 | no | - | - |

## push

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| push | push | - | partial | - | - |

## reactions

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| reactions | reactions | app/screens/reactions@v2.45.0 | partial | MattermostTests/T37ReactionTests.swift::testAliasesShareOnePillName | - |

## report_a_problem

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| report_a_problem | report_a_problem | app/screens/report_a_problem@v2.45.0 | no | - | - |

## reschedule_draft

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| reschedule_draft | reschedule_draft | app/screens/reschedule_draft@v2.45.0 | no | - | - |

## review_app

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| review_app | review_app | app/screens/review_app@v2.45.0 | no | - | - |

## scheduled_post

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| scheduled_post | scheduled_post | DELETE /posts/schedule@v4 | no | - | - |
| scheduled_post | scheduled_post | GET /posts/scheduled/team@v4 | no | - | - |
| scheduled_post | scheduled_post | PUT /posts/schedule@v4 | no | - | - |

## scheduled_post_options

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| scheduled_post_options | scheduled_post_options | app/screens/scheduled_post_options@v2.45.0 | partial | MattermostTests/T51GlobalDraftsTests.swift::testASnippetCollapsesEveryKindOfWhitespace | - |

## search

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| search | search | app/screens/search@v2.45.0 | partial | MattermostTests/T39SearchTests.swift::testEachDocumentedModifierIsParsedComposedAndSentVerbatim | - |

## select_team

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| select_team | select_team | app/screens/select_team@v2.45.0 | partial | MattermostTests/T32-TeamSidebarTests.swift::testTeamUnreadDecodesTheServersRowAndIgnoresExtraCounters | - |

## server

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| server | server | app/screens/server@v2.45.0 | partial | MattermostTests/ServerURLValidatorTests.swift::testValidServerReturnsOKWithNameProbe | - |

## settings

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| settings | settings | app/screens/settings@v2.45.0 | partial | MattermostTests/SettingsViewTests.swift::testDefaultsMirrorDesktopDefaultPreferences | - |

## share_feedback

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| share_feedback | share_feedback | app/screens/share_feedback@v2.45.0 | no | - | - |

## shell

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| shell | shell | - | partial | MattermostTests/NativeNavigationTests.swift::testChannelPathParsesTeamAndChannelName | - |

## show_translation

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| show_translation | show_translation | app/screens/show_translation@v2.45.0 | no | - | - |

## snack_bar

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| snack_bar | snack_bar | app/screens/snack_bar@v2.45.0 | no | - | - |

## sso

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| sso | sso | app/screens/sso@v2.45.0 | partial | MattermostTests/T31-AuthTests.swift::testAnAlreadySignedInWebviewIsAdoptedOnTheFirstPoll | - |

## store

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| store | store | - | partial | MattermostTests/MMStoreTests.swift::testFreshStoreIsAtCurrentSchemaVersion | - |

## table

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| table | table | app/screens/table@v2.45.0 | no | - | - |

## teams

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| teams | teams | DELETE /teams/{team_id}@v4 | no | - | - |
| teams | teams | DELETE /teams/{team_id}/members/{user_id}@v4 | no | - | - |
| teams | teams | GET /teams@v4 | no | - | - |
| teams | teams | GET /teams/{team_id}/members@v4 | no | - | - |
| teams | teams | GET /teams/{team_id}/members/{user_id}@v4 | no | - | - |
| teams | teams | GET /teams/{team_id}/stats@v4 | no | - | - |
| teams | teams | GET /users/{user_id}/teams/members@v4 | no | - | - |
| teams | teams | POST /teams@v4 | no | - | - |
| teams | teams | POST /teams/members/invite@v4 | no | - | - |
| teams | teams | POST /teams/{team_id}/invite-guests/email@v4 | no | - | - |
| teams | teams | POST /teams/{team_id}/invite/email@v4 | no | - | - |
| teams | teams | POST /teams/{team_id}/members@v4 | no | - | - |
| teams | teams | POST /teams/{team_id}/members/batch@v4 | no | - | - |
| teams | teams | POST /teams/{team_id}/members/ids@v4 | no | - | - |
| teams | teams | PUT /teams/{team_id}@v4 | no | - | - |
| teams | teams | PUT /teams/{team_id}/patch@v4 | no | - | - |

## terms_of_service

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| terms_of_service | terms_of_service | app/screens/terms_of_service@v2.45.0 | partial | MattermostTests/T49TermsOfServiceTests.swift::testPendingTermsBlockASignedInSession | - |

## thread

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| thread | thread | app/screens/thread@v2.45.0 | partial | MattermostTests/T36ThreadModelsTests.swift::testTheChainStartsWithTheRootEvenThoughTheServerReturnsItAmongTheReplies | - |

## thread_options

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| thread_options | thread_options | app/screens/thread_options@v2.45.0 | no | - | - |

## threads

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| threads | threads | GET /users/{user_id}/teams/{team_id}/threads@v4 | no | - | - |
| threads | threads | GET /users/{user_id}/teams/{team_id}/threads/{thread_id}@v4 | no | - | - |

## tos

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| tos | tos | POST /users/{user_id}/terms_of_service@v4 | no | - | - |

## transport

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| transport | transport | - | partial | MattermostTests/APIClientTests.swift::testSuccessDecodesTypedResponseAndSkipsAuthForPing | - |

## user_profile

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| user_profile | user_profile | app/screens/user_profile@v2.45.0 | partial | MattermostTests/T41ProfileTests.swift::testAProfileDecodesRolesTimezonePropsAndTheCustomStatus | - |

## users

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| users | users | DELETE /users/{user_id}/image@v4 | no | - | - |
| users | users | DELETE /users/{user_id}/status/custom@v4 | no | - | - |
| users | users | GET /users@v4 | no | - | - |
| users | users | GET /users/autocomplete@v4 | no | - | - |
| users | users | GET /users/email@v4 | no | - | - |
| users | users | GET /users/known@v4 | no | - | - |
| users | users | GET /users/sessions/attributes/manifest@v4 | no | - | - |
| users | users | GET /users/username@v4 | no | - | - |
| users | users | GET /users/{user_id}@v4 | no | - | - |
| users | users | GET /users/{user_id}/sessions@v4 | no | - | - |
| users | users | GET /users/{user_id}/status@v4 | no | - | - |
| users | users | POST /users@v4 | no | - | - |
| users | users | POST /users/group_channels@v4 | no | - | - |
| users | users | POST /users/ids@v4 | no | - | - |
| users | users | POST /users/login@v4 | no | - | - |
| users | users | POST /users/login/sso/code-exchange@v4 | no | - | - |
| users | users | POST /users/login/type@v4 | no | - | - |
| users | users | POST /users/logout@v4 | no | - | - |
| users | users | POST /users/mfa@v4 | no | - | - |
| users | users | POST /users/password/reset/send@v4 | no | - | - |
| users | users | POST /users/search@v4 | no | - | - |
| users | users | POST /users/status/ids@v4 | no | - | - |
| users | users | POST /users/usernames@v4 | no | - | - |
| users | users | POST /users/{user_id}/demote@v4 | no | - | - |
| users | users | POST /users/{user_id}/status/custom/recent/delete@v4 | no | - | - |
| users | users | PUT /users/sessions/device@v4 | no | - | - |
| users | users | PUT /users/{user_id}@v4 | no | - | - |
| users | users | PUT /users/{user_id}/patch@v4 | no | - | - |
| users | users | PUT /users/{user_id}/status@v4 | no | - | - |
| users | users | PUT /users/{user_id}/status/custom@v4 | no | - | - |

## watermark

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| watermark | watermark | app/screens/watermark@v2.45.0 | no | - | - |

## web-fallback

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| web-fallback | web-fallback | - | yes | MattermostTests/T46WebFallbackTests.swift::testTheFixedRowsAddressExactlyTheWebAppsOwnRoutes | t_a07e4108 |

## websocket

| Module | Upstream feature | Upstream ref (path@pin) | Implemented | Evidence | To be implemented |
|---|---|---|---|---|---|
| websocket | websocket | added_to_team@v4 | no | - | - |
| websocket | websocket | burn_on_read_all_revealed@v4 | no | - | - |
| websocket | websocket | channel_access_control_updated@v4 | no | - | - |
| websocket | websocket | channel_bookmark_created@v4 | no | - | - |
| websocket | websocket | channel_bookmark_deleted@v4 | no | - | - |
| websocket | websocket | channel_bookmark_sorted@v4 | no | - | - |
| websocket | websocket | channel_bookmark_updated@v4 | no | - | - |
| websocket | websocket | channel_converted@v4 | no | - | - |
| websocket | websocket | channel_created@v4 | no | - | - |
| websocket | websocket | channel_deleted@v4 | no | - | - |
| websocket | websocket | channel_member_updated@v4 | no | - | - |
| websocket | websocket | channel_restored@v4 | no | - | - |
| websocket | websocket | channel_scheme_updated@v4 | no | - | - |
| websocket | websocket | channel_updated@v4 | no | - | - |
| websocket | websocket | channel_viewed@v4 | no | - | - |
| websocket | websocket | config_changed@v4 | no | - | - |
| websocket | websocket | custom_profile_attributes_field_created@v4 | no | - | - |
| websocket | websocket | custom_profile_attributes_field_deleted@v4 | no | - | - |
| websocket | websocket | custom_profile_attributes_field_updated@v4 | no | - | - |
| websocket | websocket | custom_profile_attributes_values_updated@v4 | no | - | - |
| websocket | websocket | delete_team@v4 | no | - | - |
| websocket | websocket | direct_added@v4 | no | - | - |
| websocket | websocket | emoji_added@v4 | no | - | - |
| websocket | websocket | ephemeral_message@v4 | no | - | - |
| websocket | websocket | file_download_rejected@v4 | no | - | - |
| websocket | websocket | group_added@v4 | no | - | - |
| websocket | websocket | group_member_add@v4 | no | - | - |
| websocket | websocket | group_member_delete@v4 | no | - | - |
| websocket | websocket | hello@v4 | no | - | - |
| websocket | websocket | increase_post_visibility_by_one@v4 | no | - | - |
| websocket | websocket | leave_team@v4 | no | - | - |
| websocket | websocket | license_changed@v4 | no | - | - |
| websocket | websocket | memberrole_updated@v4 | no | - | - |
| websocket | websocket | multiple_channels_viewed@v4 | no | - | - |
| websocket | websocket | open_dialog@v4 | no | - | - |
| websocket | websocket | permission_policy_updated@v4 | no | - | - |
| websocket | websocket | ping@v4 | no | - | - |
| websocket | websocket | plugin_disabled@v4 | no | - | - |
| websocket | websocket | plugin_enabled@v4 | no | - | - |
| websocket | websocket | plugin_statuses_changed@v4 | no | - | - |
| websocket | websocket | pong@v4 | no | - | - |
| websocket | websocket | post_acknowledgement_added@v4 | no | - | - |
| websocket | websocket | post_acknowledgement_removed@v4 | no | - | - |
| websocket | websocket | post_burned@v4 | no | - | - |
| websocket | websocket | post_deleted@v4 | no | - | - |
| websocket | websocket | post_edited@v4 | no | - | - |
| websocket | websocket | post_revealed@v4 | no | - | - |
| websocket | websocket | post_translation_updated@v4 | no | - | - |
| websocket | websocket | post_unread@v4 | no | - | - |
| websocket | websocket | posted@v4 | no | - | - |
| websocket | websocket | preference_changed@v4 | no | - | - |
| websocket | websocket | preferences_changed@v4 | no | - | - |
| websocket | websocket | preferences_deleted@v4 | no | - | - |
| websocket | websocket | property_field_created@v4 | no | - | - |
| websocket | websocket | property_field_deleted@v4 | no | - | - |
| websocket | websocket | property_field_updated@v4 | no | - | - |
| websocket | websocket | property_values_updated@v4 | no | - | - |
| websocket | websocket | reaction_added@v4 | no | - | - |
| websocket | websocket | reaction_removed@v4 | no | - | - |
| websocket | websocket | received_group@v4 | no | - | - |
| websocket | websocket | received_group_associated_to_channel@v4 | no | - | - |
| websocket | websocket | received_group_associated_to_team@v4 | no | - | - |
| websocket | websocket | received_group_not_associated_to_channel@v4 | no | - | - |
| websocket | websocket | received_group_not_associated_to_team@v4 | no | - | - |
| websocket | websocket | restore_team@v4 | no | - | - |
| websocket | websocket | role_updated@v4 | no | - | - |
| websocket | websocket | scheduled_post_created@v4 | no | - | - |
| websocket | websocket | scheduled_post_deleted@v4 | no | - | - |
| websocket | websocket | scheduled_post_updated@v4 | no | - | - |
| websocket | websocket | show_toast@v4 | no | - | - |
| websocket | websocket | sidebar_category_created@v4 | no | - | - |
| websocket | websocket | sidebar_category_deleted@v4 | no | - | - |
| websocket | websocket | sidebar_category_order_updated@v4 | no | - | - |
| websocket | websocket | sidebar_category_updated@v4 | no | - | - |
| websocket | websocket | status_change@v4 | no | - | - |
| websocket | websocket | stop_typing@v4 | no | - | - |
| websocket | websocket | thread_follow_changed@v4 | no | - | - |
| websocket | websocket | thread_read_changed@v4 | no | - | - |
| websocket | websocket | thread_updated@v4 | no | - | - |
| websocket | websocket | typing@v4 | no | - | - |
| websocket | websocket | update_team@v4 | no | - | - |
| websocket | websocket | user_added@v4 | no | - | - |
| websocket | websocket | user_removed@v4 | no | - | - |
| websocket | websocket | user_role_updated@v4 | no | - | - |
| websocket | websocket | user_updated@v4 | no | - | - |
| websocket | websocket | webrtc@v4 | no | - | - |

Pins: M=v2.45.0@162f2560d0e1 W=v12.0.1@987e57120dca | rows: 311
