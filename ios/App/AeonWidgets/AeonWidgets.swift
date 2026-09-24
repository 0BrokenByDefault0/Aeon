import AppIntents
import SwiftUI
import WidgetKit

@main
struct AeonWidgetBundle: WidgetBundle {
    var body: some Widget {
        AeonTransportWidget()
        AeonPlayPauseControl()
        AeonNextTrackControl()
    }
}

/// Control Center, Lock Screen and Action button control. The system draws controls
/// from a symbol image, so this is the one place Aeon uses the system symbol set.
struct AeonPlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.isolation.sky.controls.play-pause") {
            ControlWidgetButton(action: AeonPlayPauseIntent()) {
                Label("ISOLATION", systemImage: "playpause")
            }
        }
        .displayName("Play or Pause")
        .description("Plays or pauses the record in ISOLATION.")
    }
}

struct AeonNextTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.isolation.sky.controls.next") {
            ControlWidgetButton(action: AeonNextTrackIntent()) {
                Label("Next Track", systemImage: "forward")
            }
        }
        .displayName("Next Track")
        .description("Skips to the next track in ISOLATION.")
    }
}

private struct AeonTransportEntry: TimelineEntry {
    let date: Date
}

private struct AeonTransportProvider: TimelineProvider {
    func placeholder(in context: Context) -> AeonTransportEntry { AeonTransportEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (AeonTransportEntry) -> Void) {
        completion(AeonTransportEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AeonTransportEntry>) -> Void) {
        // The widget holds no library data; it is a pair of transport buttons.
        completion(Timeline(entries: [AeonTransportEntry(date: Date())], policy: .never))
    }
}

/// Lock Screen and Home Screen transport. It carries no titles or artwork, so nothing from
/// the library is shared with the extension or shown on a locked device.
struct AeonTransportWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.isolation.sky.widgets.transport", provider: AeonTransportProvider()) { _ in
            AeonTransportWidgetView()
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("ISOLATION")
        .description("Play, pause and skip without opening the sky.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

private struct AeonTransportWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: AeonPlayPauseIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    AeonWidgetGlyph(kind: .playPause).frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play or Pause ISOLATION")
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("ISOLATION")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .tracking(1.2)
                    .widgetAccentable()
                HStack(spacing: 14) {
                    transportButton(AeonPreviousTrackIntent(), glyph: .previous, label: "Previous Track")
                    transportButton(AeonPlayPauseIntent(), glyph: .playPause, label: "Play or Pause")
                    transportButton(AeonNextTrackIntent(), glyph: .next, label: "Next Track")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(Color(red: 0.93, green: 0.90, blue: 0.84))
        }
    }

    private func transportButton<I: AppIntent>(_ intent: I, glyph: AeonWidgetGlyph.Kind, label: String) -> some View {
        Button(intent: intent) {
            AeonWidgetGlyph(kind: glyph).frame(width: 22, height: 22).frame(minWidth: 32, minHeight: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Stroked transport marks matching the app's glyph weight; no system symbols.
private struct AeonWidgetGlyph: View {
    enum Kind { case playPause, next, previous }
    let kind: Kind

    var body: some View {
        GlyphShape(kind: kind).stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .square, lineJoin: .miter))
    }

    private struct GlyphShape: Shape {
        let kind: Kind
        func path(in rect: CGRect) -> Path {
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * rect.width / 24, y: rect.minY + y * rect.height / 24)
            }
            var path = Path()
            switch kind {
            case .playPause:
                path.addLines([p(4, 5), p(13, 12), p(4, 19), p(4, 5)])
                path.move(to: p(16, 6)); path.addLine(to: p(16, 18))
                path.move(to: p(20, 6)); path.addLine(to: p(20, 18))
            case .next:
                path.addLines([p(5, 5), p(15, 12), p(5, 19), p(5, 5)])
                path.move(to: p(19, 5)); path.addLine(to: p(19, 19))
            case .previous:
                path.addLines([p(19, 5), p(9, 12), p(19, 19), p(19, 5)])
                path.move(to: p(5, 5)); path.addLine(to: p(5, 19))
            }
            return path
        }
    }
}
