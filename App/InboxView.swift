import RavenCore
import SwiftUI

struct InboxView: View {
  @Environment(AppModel.self) private var model
  var searchFocused: FocusState<Bool>.Binding

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Text(model.searchText.isEmpty ? model.mailbox.title : "Search")
          .font(.system(size: 22, weight: .bold))
          .tracking(-0.3)
        Spacer()
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
          TextField("Search", text: $model.searchText)
            .textFieldStyle(.plain)
            .focused(searchFocused)
            .onSubmit { searchFocused.wrappedValue = false }
            .onKeyPress(.escape) {
              model.searchText = ""
              searchFocused.wrappedValue = false
              return .handled
            }
          KeyCap(label: "⌘K")
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: 320, height: 34)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
      }
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 14)

      if model.mailbox == .inbox && model.searchText.isEmpty {
        HStack(spacing: 6) {
          ForEach(InboxTab.allCases) { tab in
            TabPill(title: tab.title, count: model.count(for: tab), isActive: model.tab == tab) {
              model.select(tab: tab)
            }
          }
          Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
      }

      Divider().overlay(Theme.hairline)

      if model.visibleThreads.isEmpty {
        EmptyStateView()
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(model.visibleThreads) { thread in
                ThreadRow(thread: thread, isSelected: thread.id == model.selectedID)
                  .id(thread.id)
                  .onTapGesture {
                    model.selectedID = thread.id
                    Task { await model.openSelected() }
                  }
              }
            }
            .padding(8)
          }
          .onChange(of: model.selectedID) { _, id in
            if let id { proxy.scrollTo(id) }
          }
        }
      }
    }
  }
}

struct TabPill: View {
  let title: String
  let count: Int
  let isActive: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 13, weight: .medium))
        if count > 0 {
          Text("\(count)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? Color(hex: 0xD4D4D8) : Theme.tertiary)
        }
      }
      .foregroundStyle(isActive ? .white : Color(hex: 0x3F3F46))
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background(isActive ? Theme.ink : .white, in: Capsule())
      .overlay(Capsule().strokeBorder(isActive ? Theme.ink : Theme.border))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

struct ThreadRow: View {
  let thread: MailThread
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 14) {
      Avatar(address: thread.lastFrom)
      Text(thread.lastFrom.displayName)
        .fontWeight(thread.isUnread ? .semibold : .regular)
        .lineLimit(1)
        .frame(width: 150, alignment: .leading)
      HStack(spacing: 8) {
        Text(thread.subject)
          .fontWeight(thread.isUnread ? .semibold : .regular)
        if thread.messageCount > 1 {
          Text("\(thread.messageCount)").foregroundStyle(Theme.tertiary)
        }
        Text(thread.snippet).foregroundStyle(Theme.tertiary)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      if let until = thread.snoozedUntil {
        Label(until.formatted(.dateTime.weekday(.abbreviated).hour()), systemImage: "clock")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Theme.accentInk)
      }
      Text(RowDate.format(thread.lastDate))
        .font(.system(size: 12, weight: thread.isUnread ? .semibold : .regular))
        .foregroundStyle(thread.isUnread ? Theme.ink : Theme.tertiary)
        .frame(width: 72, alignment: .trailing)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 14)
    .frame(height: 50)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(isSelected ? Theme.selection : .clear)
        .strokeBorder(isSelected ? Theme.selectionRing : .clear)
    )
    .contentShape(Rectangle())
  }
}

enum RowDate {
  static func format(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      return "Yesterday"
    }
    if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), date > weekAgo {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}

struct EmptyStateView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: model.searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(Theme.tertiary)
      Text(model.searchText.isEmpty ? "All clear" : "No results")
        .font(.system(size: 15, weight: .semibold))
      if model.isSyncing && model.searchText.isEmpty {
        Text("Syncing your mail…").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
