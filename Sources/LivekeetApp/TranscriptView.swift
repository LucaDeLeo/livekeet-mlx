import AppKit
import SwiftUI

/// A group of consecutive segments from the same speaker.
struct SpeakerGroup: Identifiable {
    let id: Int
    let speaker: String
    let channel: String
    let speakerIndex: Int
    let lines: [(id: Int, timestamp: String, text: String)]
}

struct TranscriptView: View {
    let segments: [DisplaySegment]
    var onRenameSpeaker: (String, Int, String) -> Void = { _, _, _ in }

    private var groups: [SpeakerGroup] {
        var result: [SpeakerGroup] = []
        for seg in segments {
            if let last = result.last, last.speaker == seg.speaker && last.channel == seg.channel {
                var updated = result.removeLast()
                var lines = updated.lines
                lines.append((id: seg.id, timestamp: seg.timestamp, text: seg.text))
                updated = SpeakerGroup(
                    id: updated.id,
                    speaker: updated.speaker,
                    channel: updated.channel,
                    speakerIndex: updated.speakerIndex,
                    lines: lines
                )
                result.append(updated)
            } else {
                result.append(SpeakerGroup(
                    id: seg.id,
                    speaker: seg.speaker,
                    channel: seg.channel,
                    speakerIndex: seg.speakerIndex,
                    lines: [(id: seg.id, timestamp: seg.timestamp, text: seg.text)]
                ))
            }
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(groups) { group in
                        SpeakerGroupView(group: group, onRenameSpeaker: onRenameSpeaker)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .onChange(of: segments.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private let micPalette: [Color] = [.blue, .purple, .indigo, .cyan]
private let sysPalette: [Color] = [.green, .orange, .teal, .mint]

struct SpeakerGroupView: View {
    let group: SpeakerGroup
    var onRenameSpeaker: (String, Int, String) -> Void = { _, _, _ in }

    private var isMic: Bool { group.channel == "mic" }
    private var speakerColor: Color {
        let palette = isMic ? micPalette : sysPalette
        return palette[group.speakerIndex % palette.count]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !isMic { Spacer(minLength: 60) }

            VStack(alignment: isMic ? .leading : .trailing, spacing: 2) {
                // Speaker name
                Text(group.speaker)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(speakerColor)
                    .padding(.horizontal, 4)
                    .onTapGesture {
                        onRenameSpeaker(group.channel, group.speakerIndex, group.speaker)
                    }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                // Bubble with per-line timestamps
                VStack(alignment: isMic ? .leading : .trailing, spacing: 3) {
                    ForEach(group.lines, id: \.id) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(line.timestamp)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(line.text)
                                .font(.system(size: 13))
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .id(group.lines.last?.id ?? group.id)
                .background(
                    speakerColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .frame(maxWidth: 420, alignment: isMic ? .leading : .trailing)

            if isMic { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isMic ? .leading : .trailing)
    }
}
