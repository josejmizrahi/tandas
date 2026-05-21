//
//  ActivityGroupedTimeline.swift
//  ResourceKit
//
//  Timeline rendered as date-bucketed grouped lists (Hoy / Ayer / Esta
//  semana / Este mes / mes individual). Memoizes date formatters at the
//  type level so paginated activity doesn't allocate per-row.
//

import SwiftUI
import RuulUI

struct ActivityGroupedTimeline: View {
    let items: [ActivityItem]
    let accent: Color

    var body: some View {
        VStack(spacing: 14) {
            ForEach(groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: RuulSpacing.s0) {
                    Text(group.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ruulTextSecondary)
                        .padding(.horizontal, RuulSpacing.s1)
                        .padding(.bottom, RuulSpacing.micro)

                    VStack(spacing: RuulSpacing.s0) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { i, item in
                            ActivityRowView(item: item, accent: accent)
                            if i < group.items.count - 1 {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .background(Color.ruulSurface)
                    .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
                }
            }
        }
    }

    private struct ActivityBucket { let label: String; let items: [ActivityItem] }

    private var groups: [ActivityBucket] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [String: [ActivityItem]] = [:]
        var order: [String] = []

        for item in items.sorted(by: { $0.timestamp > $1.timestamp }) {
            let label = bucketLabel(for: item.timestamp, now: now, cal: cal)
            if buckets[label] == nil { order.append(label); buckets[label] = [] }
            buckets[label]?.append(item)
        }
        return order.map { ActivityBucket(label: $0, items: buckets[$0]!) }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "MMMM"
        return f
    }()

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private func bucketLabel(for date: Date, now: Date, cal: Calendar) -> String {
        if cal.isDateInToday(date)     { return "Hoy" }
        if cal.isDateInYesterday(date) { return "Ayer" }
        if let w = cal.date(byAdding: .day, value: -7, to: now), date > w { return "Esta semana" }
        if let m = cal.date(byAdding: .month, value: -1, to: now), date > m { return "Este mes" }

        let f = cal.isDate(date, equalTo: now, toGranularity: .year)
            ? Self.monthFormatter
            : Self.monthYearFormatter
        return f.string(from: date).capitalized
    }
}

struct ActivityRowView: View {
    let item: ActivityItem
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.s3) {
            Group {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(item.kind == .neutral ? accent : item.kind.color)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .fill(item.kind == .neutral ? accent : item.kind.color)
                        .frame(width: 8, height: 8)
                        .padding(5)
                }
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: RuulSpacing.s0_5) {
                Text(item.title).font(.subheadline)
                if let s = item.subtitle {
                    Text(s).font(.caption).foregroundStyle(Color.ruulTextSecondary)
                }
            }

            Spacer(minLength: 8)

            Text(item.prebakedRelativeTime ?? relativeTime(item.timestamp))
                .font(.caption)
                .foregroundStyle(Color.ruulTextTertiary)
                .padding(.top, RuulSpacing.s0_5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, RuulSpacing.s3)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_MX")
        f.unitsStyle = .short
        return f
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
