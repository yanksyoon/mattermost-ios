# T8g — the sidebar's category headers **do** pin (T8f §4.2 is retracted), and upstream does not pin at all

Card `t_af56f51a` (architect), follow-up to T8f (`t_a3d1c600`, `docs/t8f-sidebar-list-swap.md` §4.2).
Written 2026-10-28 on `main` = `cb96dbb` (T8f merged at `400ea5e`). No behaviour change: this is a
verdict + a documentation correction.

---

## 0. Verdict, up front

The card asked one question with two branches. Both branches are wrong, in opposite directions:

1. **Upstream does not pin its category headers.** The pinned reference is
   `mattermost/mattermost-mobile` @ `162f2560` (v2.45.0). Its channel list is a **`FlashList` over a
   flat `FlattenedItem[]`**, and a category header is an **ordinary item** in that array — there is no
   `SectionList`, no `stickyHeaderIndices`, no pinned/section-header API in the channel-list path.
   Citations in §1.
2. **Our `LazyVStack(pinnedViews: [.sectionHeaders])` does pin.** Measured in T8f's *own* run: in the
   62 serialised trees that hold channel rows, the `channelSidebar.category.channels` element sits at
   **y = 166.3** in 37 of them — across **498.4 pt** of scrolling, never moving — and at **y = 386.0**
   in the 25 trees where the list is at rest, which is its in-flow position. There is no third value.
   Evidence in §2.

So: **there is nothing to fix, and there was nothing to lose.** T8f §4.2's "sticky section headers do
not stick" is a **measurement error, retracted** (§3 explains the arithmetic mistake), and the code
comment that repeats it is corrected in this card. `docs/parity.md`'s T8f bullet is corrected; the
parity table gains no stickiness promise because upstream promises none.

What *is* real and still open is T8f §4.3 — rows drawn behind the toolbar with no material over them.
Decision and follow-up card in §4.

---

## 1. Upstream evidence (`mattermost-mobile` @ `162f2560d0e1df073220f7701d5a67cc17c8abeb`)

Read from the pinned tree (Apache-2.0, behaviour reference only; nothing copied).

`app/screens/home/channel_list/categories_list/categories/categories.tsx`

```
  4  import {FlashList, type FlashListRef, type ListRenderItem, type ViewToken} from '@shopify/flash-list';
115      const renderItem: ListRenderItem<FlattenedItem> = useCallback(({item}) => {
126          if (item.type === 'header') {
127              return <CategoryHeader category={item.category}/>;
...
237              <FlashList<FlattenedItem>
239                  testID='channel_list.flat_list'
241                  renderItem={renderItem}
243                  getItemType={getItemType}
```

`app/screens/home/channel_list/categories_list/categories/helpers/flatten_categories.ts`

```
 11      | {type: 'header'; categoryId: string; category: CategoryModel}
 32  export const flattenCategories = (
 68          type: 'header',            // pushed into the same array as every channel row
```

and the list container itself, `categories_list.tsx`: `subheader`, then the `FlatList` of components
(the unread/threads buttons plus `<Categories/>`) — a header **in the column above** the list, not an
overlay:

```
        <SafeAreaView …>
            <SubHeader/>
            <FlatList data={components} … />
```

The dependency is `@shopify/flash-list` `2.3.1` (`package.json` line 55). Two consequences that matter
for parity:

* **A category header scrolls away with its channels.** That is the upstream behaviour on the pinned
  client, on phone and tablet alike: the flat list has one item stream, and the header is one of the
  items. There is no section pinning to lose.
* **The category header can be scrolled out of view, and upstream does not replace it** — the list's
  own header (`ChannelListHeader`, `SubHeader`) is fixed *above* the list, so what a reader sees over a
  scrolled list is the team header, never a category caption. Which is also why upstream has no
  "which category am I in?" affordance to match.

`docs/parity.md` therefore gains no stickiness row. The promise, stated once: **headers scroll with
their rows on both surfaces** — and the phone build happens to pin them, which is a platform
enhancement, not a deviation that needs justifying (it is what `LazyVStack(pinnedViews:)` is for).

---

## 2. Our evidence: the headers pin (measured, from T8f's own run)

Source: the T33 live run of T8f on this branch, `build/logs/t_a3d1c600/live-shots/*.txt` — 141
serialised trees, 62 of which hold `channelSidebar.channel.*` rows. One pass over every tree
(`y` of `channelSidebar.category.channels` vs the `y` of the topmost channel row):

| trees | `channelSidebar.category.channels` y | what that is |
|---|---|---|
| 25 | **386.0** | in flow: the list is at rest, and the header sits **21.7 pt above the first channel row** (row y 407.7) |
| 37 | **166.3** | **pinned**: first channel row anywhere from **−314.3** to **−812.7** (498.4 pt of scroll), header does not move |
| 0 | anything else | no intermediate, no un-pinned value |

166.3 is not a coincidence: the shell's navigation bar is `{{0.0, 56.3}, {402.0, 96.0}}`, i.e. its
bottom edge is **152.3**, and the pinned header's text starts **14 pt below it** (the caption's own
padding). In the 37 pinned trees the header's in-flow position would have been
`row_min − 21.7` — as far as **−834.4** in the most-scrolled tree, i.e. **1000.7 pt** above where it
was actually drawn.

Two structural confirmations in the same trees:

* **The header is hosted outside the row container.** Rows are children of
  `Other {{80.0, -812.7}, {306.0, 1591.7}}`; both category headers are siblings of *that* container,
  directly under the scroll content `Other {{64.0, -1420.0}, {338.0, 2211.0}}`. That is SwiftUI's
  pinned-header layout — pinned headers get their own hosting layer.
* **It is on screen, not just in the tree.** `build/logs/t8f/t8f-after-scrolled-no-sticky-header.png`
  (the run's own screenshot, the one the card cites as "shows a `#` row at the top, not a caption")
  shows the caption **`⌄ CHANNELS`** at ≈172 pt, with rows above it passing behind the toolbar.
  The file name is wrong about what it shows; §4 is what it actually demonstrates.

Not measured: the DM header pinning (no tree in the run is scrolled past the last channel row), and
the regular/iPad layout (T8f's `pinnedViews` is inside the compact grouped chrome; `.listStyle(.sidebar)`
never pinned there — T8f D1). The mechanism for every section is the same `ForEach`/`Section(header:)`
path, so one section pinning is the code path pinning.

---

## 3. Why §4.2 concluded the opposite

The check looked for a header with **`0 < y < 60`** and found none. The pin point is **166.3**, and
the reason is §2: the scroll view runs the full window (`{{64.0, 0.0}, {338.0, 874.0}}`) but the
*usable* top of the content area is the nav bar's bottom edge, **152.3** — the list scrolls under the
bar. A pinned header therefore lands below the bar, at 166.3, not at 0–60. The window excluded the very
element it was looking for.

The card's own quoted tree contains the header, annotated the wrong way:

```
Button       {{96.0, 166.3},  {274.0, 15.7}} channelSidebar.category.channels        <- in flow
```

In that tree the first channel row is at **−812.7**. A header "in flow" would be at ≈ −834.4. The
166.3 row *is* the pinned header, and it is the proof of the behaviour the note declared lost.

Nothing else in T8f's numbers changes: the element counts, the byte costs, the identifier contract and
the test results stand. Only this one paragraph was wrong.

---

## 4. T8f §4.3 — the toolbar has no material over scrolled content: **required, shell scope**

Kept separate from §0 because it is the one thing in the T8f note that is real.

Measured in the same screenshot: over a scrolled list, the rows are drawn **behind the shell's toolbar
buttons and behind the status bar** — `t44av-nooffer` overlaps the `Local Mattermost` switcher and
`t44av-mp-only` overlaps the clock — with no bar material between them. Upstream does not have this
problem *for a different reason*: its channel list header is a fixed block **above** the list (§1), so
nothing ever passes behind chrome.

That makes it a shell-chrome defect (legibility: two texts on each other), not a channel-list one, and
not a T8f regression — the `List` case is simply unmeasured (`build/logs/t_a3d1c600/base-shot.log` dies
in the app-loss class before its screenshot). **Decision: required.** Filed as **`t_560103f6`** against
`mmios-ios`, with the shell files named, because `docs/parity.md`'s "main shell chrome" row is a shell
promise and this is where it fails.

The decisive numbers for that card: `ScrollView {{64.0, 0.0}, {338.0, 874.0}}` vs
`NavigationBar {{0.0, 56.3}, {402.0, 96.0}}` in the same tree, and the screenshot above.

### §4 outcome (2026-10-28, `t_560103f6` — appended, the decision above stands)

**Landed: the bar draws material on the compact layout.** `RootView.CompactToolbarMaterial` sets
`.toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)` + `.toolbarBackground(.visible,
for: .navigationBar)` when the layout is compact **and** the pane resolves native
(`paintsCompactChrome`), on the stack's root content and on the `navigationDestination` content. The
card's option 1, scoped as it asked; option 2 was rejected because a `.safeAreaInset` moves the content
top and would have moved the pinned caption off the 166.3 this record settles. The webview pane (the
shipping configuration) is deliberately not painted and is measured unchanged: before/after differs in
1046 of 3,162,132 pixels, all of them the status-bar clock.

Measured on the same 402 × 94 pt strip of the bar, list at rest vs scrolled until rows sit behind it
(the new T33 test, `build/logs/t8g/`): **66.66 % of the strip's pixels changed before → 0.00 % after**;
the bar frame is unchanged (`{{0.0, 56.3}, {402.0, 96.0}}`), the pinned caption is still at **y = 166.3**,
and the shell's element/row counts are identical before and after (154 elements / 41 rows). The regular
iPad layout is unchanged by measurement: a before/after iPad screenshot pair differs in 134 of 4,036,560
pixels, all of them in the status-bar clock's digits. Note of record: **`docs/t560103f6-shell-chrome-material.md`**;
the fixture had to be re-seeded (347 rows / 11 categories) because this host's throwaway database no
longer held it — §1 of that note.

---

## 5. What this card changed

* `docs/t8f-sidebar-list-swap.md` — §0 item 5 and §4.2 carry a dated **correction**, and §6's open
  bullet is closed. The original text stays visible, marked superseded: a note of record is corrected,
  not rewritten.
* `docs/parity.md` — the T8f bullet's "two `List` behaviours lost" becomes one lost (the toolbar
  material) and one retracted (the headers), and the T8g bullet records the promise: headers scroll
  with their rows upstream, and our compact list pins them.
* `docs/t8e-a11y-tree-decision.md` — §4 item 2 listed "sticky section headers" as a `List` behaviour
  the swap would lose; that rationale is void and is marked so (the argument for the swap never needed
  it).
* `Mattermost/UI/Native/Sidebar/ChannelSidebarView.swift` — the comment above the `LazyVStack` no
  longer says the pinning does not work. **Comment only; no code change.**

## 6. Not claimed

* Not re-run: no UI suite, no live suite, no units were executed for this card — it changes no
  behaviour. The measurement is over T8f's existing artefacts, and the upstream reading is over the
  pinned source.
* The `LazyVStack`'s pinning is **not** claimed for the DM section or the iPad layout (not scrolled far
  enough in any captured tree / not the compact path).
* Real-device VoiceOver is unmeasured here, as in T8e/T8f: the claim is about the serialised tree and
  what the frame coordinates say, plus one screenshot.
