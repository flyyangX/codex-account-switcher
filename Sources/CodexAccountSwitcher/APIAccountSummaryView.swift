import SwiftUI

struct APIAccountSummaryView: View {
    @ObservedObject var model: APIUsageModel
    @ObservedObject var browser: APIWebBillingController
    private let accent = Color.indigo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let summary = APIAccountSummary(configuration: model.configuration)
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("账号总览", systemImage: "person.3.fill").font(.headline)
                    Text("\(summary.rows.count) 个账号").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("同步全部", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.syncAllCreditBalances() }
                    }.font(.caption).disabled(!browser.busyIDs.isEmpty || model.isDemo)
                }
                HStack(spacing: 32) {
                    totalMetric(summary.missingTotals == 0 ? "总额度" : "已知总额度", amounts: summary.totals, color: .primary)
                    Divider().frame(height: 50)
                    totalMetric(summary.missingRemaining == 0 ? "总余额" : "已知总余额", amounts: summary.remaining, color: accent)
                    Spacer(minLength: 0)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], spacing: 12) {
                    ForEach(summary.rows) { row in
                        accountTile(row, now: context.date)
                    }
                }
                HStack {
                    Text("按最近成功同步汇总 · 同一组织只计一次")
                    Spacer()
                    if summary.missingTotals > 0 || summary.missingRemaining > 0 {
                        Text("有额度待核实，合计尚不完整").foregroundStyle(.orange)
                    } else { Text("到期倒数按北京时间日期计算") }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(22)
            .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.12), lineWidth: 1))
        }
    }

    private func totalMetric(_ title: String, amounts: [String: Decimal], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if amounts.isEmpty { Text("待核实").font(.system(size: 30, weight: .semibold, design: .rounded)) }
            ForEach(amounts.keys.sorted(), id: \.self) { currency in
                Text(APIUsageFormat.compactMoney(amounts[currency]!, currency: currency))
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(color).help(APIUsageFormat.amount(amounts[currency]!, currency: currency))
            }
        }.frame(minWidth: 150, alignment: .leading)
    }

    private func accountTile(_ row: APIAccountSummary.Row, now: Date) -> some View {
        let days = row.daysUntilExpiry(now: now)
        return Button {
            if let id = row.organizationID { model.select(id) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(row.name.split(separator: "@").first.map(String.init) ?? row.name)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let days {
                        Text(days > 0 ? "\(days)" : (days == 0 ? "今天" : "已过期"))
                            .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                        if days > 0 { Text("天后到期").font(.caption) }
                        else if days == 0 { Text("到期日").font(.caption) }
                    } else { Text("到期日待核实").font(.callout) }
                    Spacer(minLength: 0)
                    Text(row.expiryDate.map { String($0.suffix(5)).replacingOccurrences(of: "-", with: "/") } ?? "—")
                        .font(.caption).foregroundStyle(.secondary)
                }.foregroundStyle(days.map { $0 <= 7 ? Color.orange : accent } ?? .secondary)
                if let balance = row.balance, let amount = balance.remainingCredits {
                    Text("余额 \(APIUsageFormat.compactMoney(amount, currency: balance.currency))")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("余额待核实").font(.caption).foregroundStyle(.secondary) }
                if let id = row.organizationID, let status = browser.statuses[id] {
                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).help(status)
                } else if let balance = row.balance {
                    Text("\(balance.verifiedAt.formatted(date: .numeric, time: .shortened)) 更新")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let balance = row.balance, now.timeIntervalSince(balance.verifiedAt) >= 30 * 60 {
                    Text("缓存超过 30 分钟").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading).padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(row.organizationID == model.organization?.id ? accent.opacity(0.4) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).help(row.name).accessibilityLabel("\(row.name)，\(days.map { $0 > 0 ? "\($0) 天后到期" : ($0 == 0 ? "今天到期" : "已过期") } ?? "到期日期待核实")")
    }
}
