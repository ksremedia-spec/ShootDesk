import Foundation

extension AppModel {
    /// The TODAY section for Ask: the week ahead, open times, the upcoming check and missing deliverables.
    /// Everything here is worked out on the phone from data the app already has; nothing extra is downloaded.
    func askToday(now: Date = Date()) -> String {
        var lines: [String] = []
        let weekEnd = FieldTime.addDays(7, to: FieldTime.startOfDay(now))

        let booked = visibleJobs
            .filter { j in guard let s = j.start else { return false }; return s >= FieldTime.startOfDay(now) && s < weekEnd }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        lines.append("BOOKED THIS WEEK (order # | when | address | agent | package | leave by)")
        if booked.isEmpty { lines.append("Nothing booked in the next 7 days.") }
        for j in booked {
            guard let s = j.start else { continue }
            let end = j.end.map { "–" + FieldTime.clockAMPM($0) } ?? ""
            let when = FieldTime.format(s, "EEE MMM d") + " " + FieldTime.clockAMPM(s) + end
            let leave = leavePlans[j.id].map { "leave by \(FieldTime.clockAMPM($0.leaveAt)) (\($0.driveLabel))" } ?? "-"
            lines.append("\(j.number) | \(when) | \(j.street), \(j.town) | \(j.agentName) | \(j.packageSummary) | \(leave)")
        }

        lines.append("\nOPEN TIMES (8 AM to sunset, 30 minutes kept clear around each shoot)")
        for day in Availability.week(from: now, jobs: visibleJobs) {
            let label = FieldTime.format(day.day, "EEE MMM d")
            let gaps = day.gaps.map { Availability.phrase($0, in: day) }
            lines.append("\(label): " + (gaps.isEmpty ? "no openings" : gaps.joined(separator: ", ")) + "; sunset \(Availability.short(day.closes))")
        }

        if let ran = checkRanAt {
            lines.append("\nUPCOMING CHECK (weather and drone airspace, run \(FieldTime.format(ran, "EEE h:mm a")))")
            if checkResults.isEmpty { lines.append("No upcoming shoots checked.") }
            for r in checkResults {
                var parts = r.issues.map { "\($0.title) (\($0.detail))" }
                parts += r.notes.map(\.text)
                if let w = r.weatherLine { parts.append(w) }
                if !r.weatherChecked { parts.append("forecast couldn't be fetched") }
                if let sug = r.suggestion { parts.append("suggested move: \(FieldTime.format(sug.date, "EEE MMM d")) (\(sug.reason))") }
                let flag = r.needsAttention ? "NEEDS KYLE" : "ok"
                lines.append("\(r.job.number) | \(r.job.street) | \(flag) | " + (parts.isEmpty ? "all clear" : parts.joined(separator: "; ")))
            }
        }

        lines.append("\nMISSING DELIVERABLES (shot 2-30 days ago, photos delivered, video or floor plan not yet in Aryeo)")
        if !flagsChecked { lines.append("Not checked yet this session.") }
        else if deliveryFlags.isEmpty { lines.append("None.") }
        for f in deliveryFlags {
            lines.append("\(f.job.number) | \(f.job.street), \(f.job.town) | \(f.job.agentName) | \(f.line) | \(f.shotLine)")
        }
        return lines.joined(separator: "\n")
    }

    /// Words Whisper should expect when Kyle talks: his agents' names and the towns he shoots in.
    /// Kept short, because Whisper only reads the last couple of hundred words of a hint.
    var voiceHint: String {
        let agents = customers.sorted { ($0.lastOrder ?? .distantPast) > ($1.lastOrder ?? .distantPast) }
            .prefix(40).map(\.name)
        let towns = Dictionary(grouping: visibleJobs.filter { !$0.town.isEmpty }, by: \.town)
            .sorted { $0.value.count > $1.value.count }.prefix(25).map(\.key)
        return "Horizon Home Media, Aryeo, Stripe. Agents: " + agents.joined(separator: ", ")
            + ". Towns: " + towns.joined(separator: ", ") + "."
    }
}
