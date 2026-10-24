import SwiftUI

/// Shown when a surface resolves to `.native` but no screen card exists for it yet — that is, it
/// is not in `SurfaceDefaults.nativeApprovedSurfaces`.
///
/// This is a deliberate, **usable** stand-in, never a blank screen: the dual-render rule is that a
/// surface may be toggled to native before its screen card ships and the app must keep working. The
/// view explains that no `-AV`-approved native screen exists yet and offers a one-tap "Use web
/// view" that returns the surface to the webview **immediately**, whatever routed it to native
/// (Surface inspector override *or* a `-surfaceMode` launch argument), so any debug toggle can
/// always be undone without relaunching.
@MainActor
struct UnportedSurfaceView: View {
    let surface: Surface
    @EnvironmentObject private var resolver: SurfaceModeResolver

    /// True while the native decision comes from this run's `-surfaceMode` flag rather than a
    /// persisted choice — the copy names the flag so the state is not a mystery.
    private var isLaunchOverridden: Bool { resolver.isLaunchOverridden(surface) }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("\(surface.title) — Native screen not ported yet")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("This surface resolved to a native render, but no screen card has been approved "
                 + "for it yet (its -AV validation has not passed). The web view stays the "
                 + "reference until a card lands, so the app keeps working.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if isLaunchOverridden {
                Text("-surfaceMode \(surface.rawValue)=native")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            Button {
                // Also drops this run's launch override for this surface, so the button works
                // even when the native decision came from `-surfaceMode`.
                resolver.forceWebForThisRun(surface)
            } label: {
                Label("Use web view", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("revertToWeb\(surface.rawValue)")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // Expose this pane as one accessibility container carrying the surface identifier, so a
        // UI test (and VoiceOver) sees a single "native stand-in for <surface>" region rather than
        // only its loose children.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unportedSurface.\(surface.rawValue)")
    }
}
