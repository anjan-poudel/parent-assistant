import SwiftUI
import MapKit

/// The in-app map fallback (directions task, 2026-09-07) — presented as an
/// app-wide sheet (ContentView) with a `pendingNavigationPresentation`-held
/// `InAppNavigationSession`, exactly like the plugin-presentation sheet.
///
/// Shows a STATIC route — MapKit polyline fitted to the screen, a
/// destination pin, and the spoken step list underneath. No live
/// re-routing, no turn-by-turn tracking (plan constraint): this is the
/// "here is the way" surface for when no map app is installed or the user
/// forced `.inApp`.
///
/// Lifecycle: the session pipeline (locate → geocode → calculate) runs
/// when the sheet appears (the coordinator calls `session.start()` when it
/// presents); `.ready` auto-speaks the steps once; Repeat speaks them
/// again, Stop cuts speech, and Back (or a swipe-dismiss) ends the
/// session via `stop()`.
struct InAppNavigationView: View {
    @ObservedObject var session: InAppNavigationSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// Whether this view already auto-spoke the steps for the ready
    /// transition — Repeat is for the user, auto-speak happens once.
    @State private var autoSpokenReadyRoute = false

    /// Computed (not stored) on purpose: a private STORED property would
    /// make the memberwise init private, and ContentView builds this
    /// sheet with `InAppNavigationView(session:)`.
    private var mapHeight: CGFloat { 280 }

    var body: some View {
        VStack(spacing: 0) {
            header
            // The map is always present (it renders the route the moment
            // `.ready` lands); the status/step area below swaps by phase.
            RouteMapView(startCoordinate: session.startCoordinate,
                         destinationCoordinate: session.destinationCoordinate,
                         destinationName: session.destinationName,
                         route: session.route)
                .frame(height: mapHeight)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius))
                .padding(.horizontal)
                .padding(.top, 4)

            contentByPhase
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .onAppear { session.start() }
        .onChange(of: session.phase) { phase in
            guard !autoSpokenReadyRoute, case .ready = phase else { return }
            autoSpokenReadyRoute = true
            Task { await session.speakSteps() }
        }
        .onDisappear { session.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .frame(minWidth: DesignTokens.minTapTargetSize,
                           minHeight: DesignTokens.minTapTargetSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.str("common.back", locale: locale))

            VStack(alignment: .leading, spacing: 2) {
                Text("directions.inApp.title")
                    .font(DesignTokens.greetingFont(size: 24))
                    .foregroundColor(DesignTokens.textPrimary)
                Text(session.destinationName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(DesignTokens.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Phase-dependent content

    @ViewBuilder
    private var contentByPhase: some View {
        switch session.phase {
        case .locating:
            statusLine("directions.inApp.locating")
        case .geocoding:
            statusLine("directions.inApp.geocoding")
        case .calculating:
            statusLine("directions.inApp.calculating")
        case .ready(let route):
            readyContent(route)
        case .failed:
            failedContent
        }
    }

    private func statusLine(_ key: String) -> some View {
        VStack(spacing: DesignTokens.interElementSpacing) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(DesignTokens.accent)
            Text(LocalizedStringKey(key))
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    private var failedContent: some View {
        VStack(spacing: DesignTokens.interElementSpacing) {
            Spacer()
            Image(systemName: "map")
                .font(.system(size: 34))
                .foregroundColor(DesignTokens.textSecondary)
            Text("directions.inApp.failed")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(DesignTokens.textPrimary)
                .multilineTextAlignment(.center)
            Text("directions.inApp.failedHint")
                .font(.system(size: 15))
                .foregroundColor(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Text("directions.inApp.close")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }

    private func readyContent(_ route: InAppRoute) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Step list header with a best-effort drive-time line.
            HStack(alignment: .firstTextBaseline) {
                Text("directions.inApp.steps")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignTokens.textSecondary)
                Spacer()
                if route.expectedTravelTime > 0 {
                    Text(L10n.fmt("directions.inApp.eta",
                                  locale: locale,
                                  minutes(route.expectedTravelTime)))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // The OS-language honesty note sits above the steps.
                    Text("directions.inApp.stepsNote")
                        .font(.system(size: 13))
                        .foregroundColor(DesignTokens.textSecondary)
                        .padding(.horizontal)
                    ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
                        stepRow(index: index + 1, instruction: step.instruction)
                    }
                    Text("directions.inApp.arrival")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DesignTokens.accent)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
                .padding(.vertical, 8)
            }

            // Control row: Repeat the steps, Stop the speech.
            HStack(spacing: 12) {
                Button {
                    Task { await session.speakSteps() }
                } label: {
                    Label {
                        Text("directions.inApp.repeat")
                    } icon: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    session.stopSpeech()
                } label: {
                    Label {
                        Text("directions.inApp.stop")
                    } icon: {
                        Image(systemName: "stop.fill")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignTokens.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: DesignTokens.minTapTargetSize)
                    .background(DesignTokens.card)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func stepRow(index: Int, instruction: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(DesignTokens.accent)
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(instruction)
                .font(.system(size: 17))
                .foregroundColor(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    private func minutes(_ travelTime: TimeInterval) -> Int {
        max(1, Int((travelTime / 60).rounded()))
    }
}

// MARK: - Map

/// The static-route MKMapView (directions task, 2026-09-07). Draws the
/// route polyline in the app's accent, pins the destination, and fits the
/// visible region to the route once — re-centering ONLY when the geometry
/// actually changed (never on incidental SwiftUI re-renders, which would
/// fight the user's pan).
///
/// Deliberately NO live user dot: the location permission ask is owned by
/// the session's `LocationFetcher` at the point of use — the map must not
/// trigger a second system prompt — and a static route needs no tracking.
private struct RouteMapView: UIViewRepresentable {
    let startCoordinate: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
    let destinationName: String
    let route: InAppRoute?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Geometry signature — refit/replace only when it truly changes.
        let signature = "\(route?.polylineCoordinates.count ?? -1)|"
            + "\(destinationCoordinate?.latitude ?? 0),\(destinationCoordinate?.longitude ?? 0)"
        guard signature != context.coordinator.appliedSignature else { return }
        context.coordinator.appliedSignature = signature

        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        if let route, route.polylineCoordinates.count >= 2 {
            let polyline = MKPolyline(coordinates: route.polylineCoordinates,
                                      count: route.polylineCoordinates.count)
            map.addOverlay(polyline)
            map.setVisibleMapRect(fitRect(for: polyline.boundingMapRect),
                                  edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                                  animated: false)
        } else if let destinationCoordinate {
            // Pre-route phases (geocoding/calculating): center the pin.
            map.setRegion(MKCoordinateRegion(center: destinationCoordinate,
                                             latitudinalMeters: 1200,
                                             longitudinalMeters: 1200),
                          animated: false)
        }

        if let destinationCoordinate {
            let pin = MKPointAnnotation()
            pin.coordinate = destinationCoordinate
            pin.title = destinationName
            map.addAnnotation(pin)
        }
        // startCoordinate is deliberately unused for drawing: the fitted
        // route rect spans origin and destination.
        _ = startCoordinate
    }

    /// A visible map rect around the route with some breathing room. A
    /// degenerate (near-zero-size) rect falls back to a fixed-span region
    /// centered on the route's first point.
    private func fitRect(for routeRect: MKMapRect) -> MKMapRect {
        if routeRect.size.width < 10 || routeRect.size.height < 10 {
            return MKMapRect(
                x: routeRect.origin.x - 500, y: routeRect.origin.y - 500,
                width: 1000, height: 1000)
        }
        return routeRect
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var appliedSignature: String?
    }
}

extension RouteMapView.Coordinator {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor(DesignTokens.accent)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}
