import Foundation

/// A made-up mailbox for demo mode, screenshots and previews. All names are fictional.
public enum SampleMail {
  public static func messages(now: Date = Date()) -> [Message] {
    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    let me = Address(name: "You", email: "you@example.com")
    let priya = Address(name: "Priya Raman", email: "priya@example.com")
    let marcus = Address(name: "Marcus Lee", email: "marcus@example.com")
    let dana = Address(name: "Dana Okafor", email: "dana@example.com")
    let elena = Address(name: "Elena Petrova", email: "elena@example.com")
    let jordan = Address(name: "Jordan Kim", email: "jordan@example.com")
    let sam = Address(name: "Sam Ortiz", email: "sam@example.com")
    let travel = Address(name: "Northwind Travel", email: "trips@northwind.example")
    let byte = Address(name: "The Weekly Byte", email: "hello@weeklybyte.example")
    let ember = Address(name: "Ember Coffee", email: "receipts@ember.example")
    let inbox: Set<String> = [Label.inbox]
    let unread: Set<String> = [Label.inbox, Label.unread]

    return [
      Message(
        id: "m1a", threadID: "t1", from: marcus, to: [priya, me], date: ago(60 * 20),
        subject: "Q4 roadmap review", snippet: "Works for me — I'll bring the beta numbers.",
        bodyText: "Works for me — I'll bring the beta numbers.\n\nMarcus", labels: inbox.union([Label.important])),
      Message(
        id: "m1b", threadID: "t1", from: priya, to: [me, marcus], date: ago(18),
        subject: "Re: Q4 roadmap review", snippet: "Can you confirm Thursday at 2pm still works?",
        bodyText: "Hi! Can you confirm Thursday at 2pm still works? I'd also love your call on A vs B before we walk in. And could you resend the headcount numbers?\n\nThanks — P",
        labels: unread.union([Label.important])),
      Message(
        id: "m2", threadID: "t2", from: marcus, to: [me], date: ago(62),
        subject: "Offsite venue options", snippet: "Shortlisted two places in Hudson, both hold 40.",
        bodyText: "Shortlisted two places in Hudson, both hold 40. Photos attached. Want to do a site visit next week?\n\nM",
        labels: unread.union([Label.important])),
      Message(
        id: "m3", threadID: "t3", from: dana, to: [me], date: ago(105),
        subject: "Contract redlines (v3)", snippet: "Legal is fine with 4.2 but wants the cap restated.",
        bodyText: "Legal is fine with 4.2 but wants the indemnity cap restated in 7.1. Redlines attached — can you take a look by Friday?\n\nDana",
        labels: unread.union([Label.important])),
      Message(
        id: "m4", threadID: "t4", from: elena, to: [me, sam], date: ago(150),
        subject: "Intro: Elena ↔ Sam", snippet: "Sam leads design systems at Fieldnote.",
        bodyText: "Moving myself to bcc! Sam leads design systems at Fieldnote and wanted to compare notes on keyboard-first UI. I'll let you two take it from here.",
        labels: unread.union([Label.important])),
      Message(
        id: "m5", threadID: "t5", from: jordan, to: [me], date: ago(60 * 26),
        subject: "Review my PR before EOD?", snippet: "Small one — the sync retry backoff.",
        bodyText: "Small one — the sync retry backoff. Should be a quick read.", labels: inbox.union([Label.important])),
      Message(
        id: "m6", threadID: "t6", from: travel, to: [me], date: ago(60 * 28),
        subject: "Your itinerary for Nov 14", snippet: "JFK → SFO, seat 12A.",
        bodyText: "Your trip is confirmed.\n\nJFK → SFO\nNov 14, 8:05 AM\nSeat 12A", labels: inbox.union([Label.updates])),
      Message(
        id: "m7", threadID: "t7", from: sam, to: [me], date: ago(60 * 50),
        subject: "Coffee next week?", snippet: "Tuesday or Wednesday morning works for me.",
        bodyText: "Tuesday or Wednesday morning works for me. There's a good spot near Prospect Park.", labels: inbox),
      Message(
        id: "m8", threadID: "t8", from: byte, to: [me], date: ago(60 * 9),
        subject: "Issue #142: Local-first is back", snippet: "This week: sync engines, CRDTs, and why fast apps feel calm.",
        bodyText: "This week: sync engines, CRDTs, and why fast apps feel calm.", labels: unread.union([Label.promotions]),
        listID: "<weeklybyte.example>"),
      Message(
        id: "m9", threadID: "t9", from: ember, to: [me], date: ago(60 * 30),
        subject: "Your receipt from Ember Coffee", snippet: "Oat flat white, $5.25.",
        bodyText: "Thanks for stopping by!\n\nOat flat white   $5.25", labels: inbox.union([Label.updates])),
    ]
  }
}
