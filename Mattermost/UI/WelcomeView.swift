import SwiftUI
import Combine

// MARK: - Slide model

/// A single onboarding slide. Native counterpart of the desktop `WelcomeScreen` slide literal
/// (title/subtitle/image). The desktop renders raster illustrations (`ThreadsEmptyImage`,
/// `CollaborateImage`, `CallsImage`, `ToolsImage`); iOS analog substitutes an SF Symbol glyph
/// over a per-slide gradient tint since the desktop PNG assets are not part of the app bundle.
struct WelcomeSlide: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    /// The desktop marks the first slide `main: true` and styles it larger.
    var isMain: Bool = false
    let tint: Color

    /// The four slides the desktop `WelcomeScreen` presents, in order and with its copy.
    static let defaultSlides: [WelcomeSlide] = [
        WelcomeSlide(
            id: "welcome",
            title: "Welcome",
            subtitle: "Mattermost is a sovereign collaboration platform built for operational environments and uncompromising security.",
            systemImage: "bubble.left.and.bubble.right.fill",
            isMain: true,
            tint: Color(red: 0.20, green: 0.46, blue: 0.98)
        ),
        WelcomeSlide(
            id: "collaborate",
            title: "Collaborate in real-time",
            subtitle: "Coordinate across teams with persistent mission channels, secure file sharing, and automated workflows.",
            systemImage: "person.2.fill",
            tint: Color(red: 0.16, green: 0.68, blue: 0.48)
        ),
        WelcomeSlide(
            id: "calls",
            title: "Start secure calls instantly",
            subtitle: "Seamlessly move from chat to audio calls and screen sharing without switching tools or losing context.",
            systemImage: "phone.fill",
            tint: Color(red: 0.91, green: 0.44, blue: 0.20)
        ),
        WelcomeSlide(
            id: "integrate",
            title: "Integrate with your systems",
            subtitle: "Centralize data feeds, automate alerts, and integrate custom tooling directly into your operational hub.",
            systemImage: "square.grid.2x2.fill",
            tint: Color(red: 0.55, green: 0.32, blue: 0.87)
        ),
    ]
}

// MARK: - Pager state machine

/// Pure pager state machine powering the `WelcomeView` carousel. Native counterpart of the
/// desktop `Carousel` component's index/`autoChange` logic (`Carousel.tsx`): wraps at both ends,
/// cycles a `currentIndex`, and tracks whether the auto-advance timer is still allowed to run.
///
/// Split out of the view so the wrap/advance behaviour is unit-testable without a UI host.
/// The auto-advance **timer** lives in `WelcomeView` (driven by `autoconnect()` timer events),
/// matching the desktop's `setTimeout(5000)`; this model only decides what a tick does.
@MainActor
final class WelcomePagerModel: ObservableObject {

    /// 5 s, mirroring the desktop `Carousel`'s `AUTO_CHANGE_TIME = 5000`.
    static let autoAdvanceInterval: TimeInterval = 5

    @Published private(set) var currentIndex: Int
    /// Mirrors desktop `autoChange`: any manual navigation (prev/next/dot/swipe) flips it off,
    /// disabling further auto-advance for the life of this carousel instance.
    @Published private(set) var autoAdvances: Bool
    let pageCount: Int

    init(pageCount: Int, startIndex: Int = 0) {
        self.pageCount = pageCount
        self.currentIndex = max(0, startIndex)
        self.autoAdvances = true
    }

    /// Desktop Carousel's `disableNavigation = slides.length <= 1`.
    var disableNavigation: Bool { pageCount <= 1 }

    // MARK: Manual navigation (disables auto-advance, mirroring desktop handlers)

    func goNext() { move(to: currentIndex + 1); autoAdvances = false }
    func goPrev() { move(to: currentIndex - 1); autoAdvances = false }
    func jump(to index: Int) { move(to: index); autoAdvances = false }

    // MARK: Auto tick

    /// Called by the view's timer on each 5 s tick. Only advances while auto-advance remains
    /// enabled and does **not** disable it itself — exactly the desktop distinction between its
    /// auto `handleOnNextButtonClick(true)` and a real click.
    func advanceAuto() {
        guard autoAdvances, pageCount > 1 else { return }
        move(to: currentIndex + 1)
    }

    private func move(to requested: Int) {
        guard pageCount > 0 else {
            currentIndex = 0
            return
        }
        if requested < 0 {
            currentIndex = pageCount - 1
        } else if requested >= pageCount {
            currentIndex = 0
        } else {
            currentIndex = requested
        }
    }
}

// MARK: - View

/// First-run onboarding pager. Native counterpart of the desktop renderer's `WelcomeScreen` +
/// `Carousel` (+ `CarouselButton`, `CarouselPaginationIndicator`, `WelcomeScreenSlide`).
///
/// Shows a swipeable page carousel (auto-advancing every 5 s until the user interacts), a
/// pagination row of dots flanked by prev/next chevrons, and a prominent "Get started" button
/// that hands off to the add-server form. Parity rows: `WelcomeScreen` -> `WelcomeView`,
/// `Carousel` -> pager + `WelcomePagerModel`. Status: native, P3.
struct WelcomeView: View {

    let slides: [WelcomeSlide]
    var onGetStarted: () -> Void = {}

    @StateObject private var model: WelcomePagerModel
    @State private var hasAutoAdvanced = false

    init(slides: [WelcomeSlide], startPage: Int = 0, onGetStarted: @escaping () -> Void = {}) {
        self.slides = slides
        self.onGetStarted = onGetStarted
        _model = StateObject(wrappedValue: WelcomePagerModel(
            pageCount: slides.count,
            startIndex: startPage
        ))
    }

    /// Selection binding over the page TabView; any swipe forwards into `jump(to:)`, which
    /// (like a manual click) disables subsequent auto-advance.
    private var pageSelection: Binding<Int> {
        Binding(
            get: { model.currentIndex },
            set: { model.jump(to: $0) }
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [currentSlide.tint.opacity(0.22), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                TabView(selection: pageSelection) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                        WelcomeSlideView(slide: slide)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                paginationRow
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)

                getStartedButton
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
        }
        .task {
            // Auto-advance loop: mirrors the desktop `Carousel`'s 5 s `setTimeout` chain
            // (`AUTO_CHANGE_TIME`), but as a cancellation-aware repeating task. Each manual
            // interaction flips `autoAdvances` off, after which `advanceAuto()` becomes a no-op
            // for the rest of this carousel's life (desktop `autoChange = false`).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WelcomePagerModel.autoAdvanceInterval))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.advanceAuto()
                }
            }
        }
        .accessibilityIdentifier("welcomeView")
    }

    // MARK: Subviews

    private var currentSlide: WelcomeSlide {
        guard slides.indices.contains(model.currentIndex) else {
            return slides.first ?? WelcomeSlide(id: "", title: "", subtitle: "", systemImage: "circle.fill", tint: .secondary)
        }
        return slides[model.currentIndex]
    }

    /// Prev chevron · pagination dots · next chevron, mirroring `Carousel__pagination`
    /// (`CarouselButton` + `CarouselPaginationIndicator`).
    private var paginationRow: some View {
        HStack(spacing: 24) {
            Button {
                model.goPrev()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
            }
            .disabled(model.disableNavigation)
            .accessibilityLabel("Previous page")
            .accessibilityIdentifier("prevCarouselButton")

            WelcomePageDots(pageCount: model.pageCount, activePage: model.currentIndex) { index in
                model.jump(to: index)
            }
            .frame(maxWidth: .infinity)

            Button {
                model.goNext()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
            }
            .disabled(model.disableNavigation)
            .accessibilityLabel("Next page")
            .accessibilityIdentifier("nextCarouselButton")
        }
    }

    private var getStartedButton: some View {
        Button(action: onGetStarted) {
            Text("Get started")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("getStartedWelcomeScreen")
    }
}

/// One slide's content: glyph, title, subtitle. Port of `WelcomeScreenSlide`.
private struct WelcomeSlideView: View {
    let slide: WelcomeSlide

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: slide.systemImage)
                .font(.system(size: slide.isMain ? 72 : 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(slide.tint)
                .padding(28)
                .background(
                    Circle()
                        .fill(slide.tint.opacity(0.14))
                        .frame(width: slide.isMain ? 168 : 148, height: slide.isMain ? 168 : 148)
                )
                .padding(.bottom, 8)

            Text(slide.title)
                .font(slide.isMain ? .title.weight(.bold) : .title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(slide.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// The dot indicators (port of `CarouselPaginationIndicator`), clickable per page.
private struct WelcomePageDots: View {
    let pageCount: Int
    let activePage: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Button {
                    onSelect(index)
                } label: {
                    Circle()
                        .fill(activePage == index ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: activePage == index ? 8 : 7,
                               height: activePage == index ? 8 : 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(index + 1)")
                .accessibilityIdentifier("PaginationIndicator\(index)")
            }
        }
        .disabled(pageCount <= 1)
    }
}

// MARK: - Preview

#Preview {
    WelcomeView(slides: WelcomeSlide.defaultSlides) {}
}