import SwiftUI

/// 簡訊：仿「訊息」App。左邊依號碼分組的對話列表，右邊是氣泡對話
struct PhoneSMSView: View {
    let messages: [PhoneSMS]
    let query: String
    @State private var selected: String?

    private struct Conversation: Identifiable {
        var id: String            // 號碼
        var messages: [PhoneSMS]  // 由舊到新
        var last: PhoneSMS { messages[messages.count - 1] }
    }

    private var conversations: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return Dictionary(grouping: messages, by: \.address)
            .map { Conversation(id: $0.key, messages: $0.value.sorted { $0.date < $1.date }) }
            .filter { q.isEmpty || $0.id.localizedCaseInsensitiveContains(q) || $0.messages.contains { $0.body.localizedCaseInsensitiveContains(q) } }
            .sorted { $0.last.date > $1.last.date }
    }

    var body: some View {
        let list = conversations
        HStack(spacing: 12) {
            conversationList(list)
                .frame(width: 290)
                .liquidPanel(cornerRadius: 22)
            thread(list.first { $0.id == selected } ?? list.first)
                .liquidPanel(cornerRadius: 22)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .overlay { if list.isEmpty { Text("沒有簡訊").foregroundStyle(.secondary) } }
    }

    // MARK: 對話列表

    private func conversationList(_ list: [Conversation]) -> some View {
        let current = selected ?? list.first?.id
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(list) { c in
                    let on = c.id == current
                    HStack(alignment: .top, spacing: 10) {
                        avatar(34)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(c.id).font(.headline).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(shortDate(c.last.date)).font(.caption)
                                    .foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                            }
                            Text(c.last.body).font(.callout).lineLimit(2)
                                .foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                        }
                    }
                    .foregroundStyle(on ? .white : .primary)
                    .padding(10)
                    .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = c.id }
                    if c.id != list.last?.id { Divider().padding(.leading, 56).padding(.trailing, 10) }
                }
            }
            .padding(8)
        }
    }

    // MARK: 對話

    @ViewBuilder
    private func thread(_ c: Conversation?) -> some View {
        if let c {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    avatar(44)
                    Text(c.id).font(.headline)
                    Text("簡訊 · \(c.messages.count) 則").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(c.messages.enumerated()), id: \.element.id) { i, m in
                                if i == 0 || m.date.timeIntervalSince(c.messages[i - 1].date) > 3600 {
                                    Text(separatorDate(m.date)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        .padding(.top, 10).padding(.bottom, 2)
                                }
                                bubble(m)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(14)
                    }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: c.id) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: c.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .id(c.id)
        }
    }

    private func bubble(_ m: PhoneSMS) -> some View {
        HStack {
            if m.isSent { Spacer(minLength: 70) }
            Text(m.body)
                .textSelection(.enabled)
                .fontWeight(m.isSent ? .medium : .regular)
                .foregroundStyle(m.isSent ? .white : .primary)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(m.isSent ? Color(red: 0.20, green: 0.62, blue: 0.32) : Color.secondary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !m.isSent { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity, alignment: m.isSent ? .trailing : .leading)
    }

    private func avatar(_ size: CGFloat) -> some View {
        Circle().fill(Color.secondary.opacity(0.35))
            .overlay(Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(.white.opacity(0.9)))
            .frame(width: size, height: size)
    }

    private func shortDate(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.year().month(.defaultDigits).day())
    }

    private func separatorDate(_ d: Date) -> String {
        d.formatted(Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
                    ? .dateTime.month().day().weekday().hour().minute()
                    : .dateTime.year().month().day().hour().minute())
    }
}
