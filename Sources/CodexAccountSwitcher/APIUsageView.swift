import AppKit
import SwiftUI
import Charts
import SwitcherCore

enum APIUsageFormat {
    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date) + " +08:00"
    }
    static func amount(_ amount: Decimal, currency: String) -> String {
        var value = NSDecimalNumber(decimal: amount).stringValue
        if !value.lowercased().contains("e") {
            if !value.contains(".") { value += ".00" }
            else if value.split(separator: ".").last?.count == 1 { value += "0" }
        }
        return currency.uppercased() + " " + value
    }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: date)
    }
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

struct APIUsageView: View {
    @ObservedObject var model: APIUsageModel
    @State private var organizationEditor: OrganizationEditorTarget?
    @State private var grantEditor: GrantEditorTarget?
    @State private var showsRemoval = false
    @State private var showsAccountEditor = false
    @State private var accountName = ""
    @State private var expiryEditor: APITrackedAccount?
    @State private var expiryInput = ""
    @State private var showsCustomPeriod = false
    @State private var showsDetails = false
    @State private var showsBalanceEditor = false
    @State private var page = "overview"
    private let accent = Color.indigo

    private var account: APITrackedAccount? {
        model.configuration.accounts.first { $0.organizationID == model.organization?.id }
    }
    private var title: String { account?.name ?? model.organization?.name ?? "API Monitor" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if model.isDemo {
                            notice("演示模式 · 图表与金额均为合成数据", icon: "testtube.2", color: .orange)
                        }
                        if let message = model.message {
                            HStack {
                                notice(message, icon: "info.circle", color: .orange)
                                Button { model.message = nil } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help("关闭提示")
                            }
                        }
                        if model.organization != nil {
                            if page == "overview" { overview } else { creditsPage }
                        } else {
                            ContentUnavailableView {
                                Label("连接第一份 API 账单", systemImage: "chart.xyaxis.line")
                            } description: {
                                Text("连接组织后，费用趋势、模型用量和到期提醒会显示在这里。")
                            } actions: {
                                Button("连接组织") { organizationEditor = OrganizationEditorTarget(organization: nil) }
                                    .buttonStyle(.borderedProminent)
                            }.frame(minHeight: 450)
                        }
                    }.padding(28)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(accent)
        .frame(minWidth: 1020, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $organizationEditor) { target in
            APIOrganizationEditor(model: model, existing: target.organization, accountID: target.accountID)
        }
        .sheet(isPresented: $showsBalanceEditor) { APICreditBalanceEditor(model: model) }
        .sheet(isPresented: $showsCustomPeriod) { APIPeriodEditor(model: model) }
        .sheet(isPresented: $showsDetails) { detailsSheet }
        .sheet(isPresented: $showsAccountEditor) { accountSheet }
        .sheet(item: $grantEditor) { target in
            if let org = model.organization { APICreditEditor(model: model, organizationID: org.id, existing: target.grant) }
        }
        .sheet(item: $expiryEditor) { account in
            VStack(alignment: .leading, spacing: 16) {
                Label("\(account.name) · 到期日期", systemImage: "calendar.badge.clock").font(.headline)
                TextField("已知到期日期", text: $expiryInput, prompt: Text("YYYY-MM-DD；留空清除"))
                    .textFieldStyle(.roundedBorder)
                Text("仅记录日期；提前 3 天与 1 天的北京时间 09:00 提醒。精确到期时刻仍待核实。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("取消") { expiryEditor = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存日期") {
                        Task {
                            do { try await model.setDateOnlyExpiry(accountID: account.id, date: expiryInput); expiryEditor = nil }
                            catch { model.message = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(width: 480)
            .onAppear { expiryInput = account.expiryDate ?? "" }
        }
        .confirmationDialog("移除组织及其全部本地记录？", isPresented: $showsRemoval) {
            Button("移除组织、密钥、缓存与赠额记录", role: .destructive) {
                Task { do { try await model.removeOrganization() } catch { model.message = error.localizedDescription } }
            }
        } message: { Text("会取消该组织的待发送提醒，不修改 OpenAI 官方账单或组织配置。") }
        .task { model.start() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(accent.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("API Monitor").font(.system(size: 17, weight: .bold))
                    Text("用量与费用").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 12)
            VStack(spacing: 6) {
                navRow("账单概览", icon: "square.grid.2x2", value: "overview")
                navRow("赠额与提醒", icon: "gift", value: "credits")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("账号").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { showsAccountEditor = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).help("登记账号").accessibilityLabel("登记账号")
                }.padding(.horizontal, 10)
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(model.configuration.accounts) { item in
                            accountRow(name: item.name, orgID: item.organizationID, accountID: item.id)
                        }
                        ForEach(model.configuration.organizations.filter { org in
                            !model.configuration.accounts.contains { $0.organizationID == org.id }
                        }) { org in
                            accountRow(name: org.name, orgID: org.id, accountID: nil)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                Label("每 15 分钟自动同步", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Link(destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!) {
                    HStack { Text("OpenAI 官方账单"); Spacer(); Image(systemName: "arrow.up.right") }
                }.font(.caption).buttonStyle(.plain)
            }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }.padding(18).frame(width: 225).background(.regularMaterial)
    }

    private func navRow(_ label: String, icon: String, value: String) -> some View {
        Button { page = value } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 20)
                Text(label).fontWeight(page == value ? .semibold : .regular)
                Spacer()
            }.padding(12).contentShape(Rectangle())
                .foregroundStyle(page == value ? accent : .primary)
                .background(page == value ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func accountRow(name: String, orgID: String?, accountID: UUID?) -> some View {
        let selected = orgID != nil && model.organization?.id == orgID
        return Button {
            if let orgID { model.select(orgID) }
            else { organizationEditor = OrganizationEditorTarget(organization: nil, accountID: accountID) }
        } label: {
            HStack(spacing: 10) {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30).background(selected ? accent.opacity(0.14) : .primary.opacity(0.06), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.contains("@") ? String(name.split(separator: "@")[0]) : name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(orgID == nil ? "点击连接账单" : "已连接组织").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected { Circle().fill(accent).frame(width: 6, height: 6) }
            }.padding(10).contentShape(Rectangle())
                .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).help(name).accessibilityLabel("账号：\(name)")
            .contextMenu {
                if let item = model.configuration.accounts.first(where: { $0.id == accountID }) {
                    Button("设置到期日期") { expiryEditor = item }
                }
            }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page == "overview" ? "账单概览" : "赠额与提醒").font(.system(size: 25, weight: .bold))
                Text(title).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small); Text("同步中").font(.caption).foregroundStyle(.secondary) }
            Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(model.isRefreshing || model.isDemo || model.organization == nil)
            Menu {
                Button("添加组织") { organizationEditor = OrganizationEditorTarget(organization: nil) }
                if model.organization != nil {
                    Button("组织与连接设置") { organizationEditor = OrganizationEditorTarget(organization: model.organization) }
                    Button("断开并清理此组织密钥") { do { try model.disconnect() } catch { model.message = error.localizedDescription } }
                    Button("移除此组织…", role: .destructive) { showsRemoval = true }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                .frame(width: 24).disabled(model.isDemo).help("连接设置").accessibilityLabel("连接设置")
        }.padding(.horizontal, 28).padding(.vertical, 22)
        .background(.bar)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            balanceCard
            periodBar
            if model.isRefreshing {
                notice("正在载入所选周期，下方保留上次结果。", icon: "arrow.triangle.2.circlepath", color: accent)
            }
            if let error = model.snapshot?.cycle.error ?? model.snapshot?.usage.error {
                notice("同步未完成 · \(error) 缓存以所示日期为准。", icon: "exclamationmark.triangle", color: .orange)
            } else if !model.isRefreshing, model.snapshot?.cycle.isStale(now: Date()) == true {
                notice("账单缓存已超过 30 分钟，请刷新后查看最新结果。", icon: "clock", color: .orange)
            }
            HStack(spacing: 14) {
                costMetric
                numberMetric("请求次数", icon: "arrow.up.arrow.down", value: usageTotal(\.requests), suffix: "次", color: .teal)
                numberMetric("Token 用量", icon: "sparkles", value: tokenTotal, suffix: "输入 + 输出", color: .purple)
            }
            APICostTrendCard(report: model.snapshot?.cycle)
            HStack(alignment: .top, spacing: 16) {
                modelCard.frame(maxWidth: .infinity)
                expiryCard.frame(width: 245)
            }
            HStack {
                Label("官方日桶 · UTC · 数据可能延迟", systemImage: "info.circle")
                Spacer()
                Button("数据明细与统计口径") { showsDetails = true }.buttonStyle(.link)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var periodBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                ForEach([APIPeriodPreset.today, .last7Days, .last30Days, .thisMonth, .lastMonth], id: \.self) { preset in
                    Button { choose(preset) } label: {
                        Text(preset.title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(model.period.preset == preset ? .white : .primary)
                            .background(model.period.preset == preset ? accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("选择起止日期…") { showsCustomPeriod = true }
                    Button("使用已设周期") { choose(.configured) }
                } label: {
                    Label(model.period.preset == .configured ? "已设周期" : "自定义", systemImage: "calendar")
                }.fixedSize()
            }
            HStack {
                if let range = model.snapshot?.cycle.range {
                    Text("所示数据  \(APIUsageFormat.rangeLabel(range))")
                } else { Text("连接后显示所选周期数据") }
                Spacer()
                if let fetched = model.snapshot?.cycle.fetchedAt {
                    Text("\(fetched.formatted(date: .omitted, time: .shortened)) 更新")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose(_ preset: APIPeriodPreset) {
        do { try model.setPeriod(APIPeriodSelection(preset: preset)) }
        catch { model.message = error.localizedDescription }
    }
    private func usageTotal(_ path: KeyPath<APIModelUsage, Int64>) -> Decimal? {
        model.snapshot?.usage.value.map { $0.models.reduce(Decimal.zero) { $0 + Decimal($1[keyPath: path]) } }
    }
    private var tokenTotal: Decimal? {
        guard let input = usageTotal(\.inputTokens), let output = usageTotal(\.outputTokens) else { return nil }
        return input + output
    }

    private var costMetric: some View {
        APIDashboardCard {
            Label("所示范围费用", systemImage: "creditcard").font(.caption.weight(.medium)).foregroundStyle(accent)
            if let totals = model.snapshot?.cycle.value?.totals, !totals.isEmpty {
                ForEach(totals.keys.sorted(), id: \.self) { currency in
                    Text(APIUsageFormat.compactMoney(totals[currency]!, currency: currency))
                        .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                        .help(APIUsageFormat.amount(totals[currency]!, currency: currency))
                }
                Text("官方 Costs · 非剩余额").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").font(.system(size: 29, weight: .semibold, design: .rounded))
                Text(model.snapshot?.cycle.value == nil ? "等待账单同步" : "暂无费用条目").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func numberMetric(_ title: String, icon: String, value: Decimal?, suffix: String, color: Color) -> some View {
        APIDashboardCard {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(color)
            Text(value.map(APIUsageFormat.compactNumber) ?? "—")
                .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            Text(suffix).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modelCard: some View {
        APIDashboardCard {
            HStack { Text("模型用量").font(.headline); Spacer(); Text("Token").font(.caption).foregroundStyle(.secondary) }
            if let usage = model.snapshot?.usage.value, !usage.models.isEmpty {
                let rows = usage.models.sorted { Double($0.inputTokens) + Double($0.outputTokens) > Double($1.inputTokens) + Double($1.outputTokens) }
                let maximum = rows.map { Double($0.inputTokens) + Double($0.outputTokens) }.max() ?? 1
                ForEach(rows.prefix(4)) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(row.model).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(APIUsageFormat.compactNumber(Decimal(row.inputTokens) + Decimal(row.outputTokens)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(accent.opacity(0.07))
                                Capsule().fill(accent.gradient).frame(width: geometry.size.width * min(1, (Double(row.inputTokens) + Double(row.outputTokens)) / max(1, maximum)))
                            }
                        }.frame(height: 7)
                    }.padding(.top, 6)
                }
                Button("查看全部模型与明细") { showsDetails = true }.buttonStyle(.link).font(.caption).padding(.top, 6)
            } else {
                smallEmpty("暂无模型用量", subtitle: "当前范围尚无官方用量条目", icon: "waveform.path")
            }
            if let range = model.snapshot?.usage.range, range != model.snapshot?.cycle.range {
                Text("用量范围：\(APIUsageFormat.rangeLabel(range))").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var expiryCard: some View {
        APIDashboardCard {
            HStack { Label("到期提醒", systemImage: "gift").font(.headline); Spacer() }
            if let date = account?.expiryDate {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(date.suffix(5)).replacingOccurrences(of: "-", with: "/"))
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("到期日").font(.caption).foregroundStyle(.secondary)
                }.foregroundStyle(.orange)
                Text("精确时刻待核实").font(.caption).foregroundStyle(.secondary)
            } else if let grant = model.grants.first(where: { $0.expiresAt > Date() }) {
                Text(grant.expiresAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
                Text("最近批次到期").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "calendar.badge.questionmark").font(.system(size: 30)).foregroundStyle(.orange.opacity(0.7)).padding(.top, 8)
                Text("到期日期待补充").font(.callout.weight(.medium))
            }
            Text(model.creditBalance?.remainingCredits == nil ? "官方剩余额待核验" : "余额见上方核对记录").font(.caption).foregroundStyle(.secondary)
            if page == "overview" { Button("管理赠额与提醒") { page = "credits" }.buttonStyle(.link).font(.caption).padding(.top, 6) }
        }
    }

    private var balanceCard: some View {
        let balance = model.creditBalance
        return HStack(spacing: 24) {
            ZStack {
                Circle().stroke(accent.opacity(0.12), lineWidth: 7)
                if let total = balance?.totalCredits, let remaining = balance?.remainingCredits,
                   balance?.isInitialGrantOnly == false, total > 0, remaining <= total {
                    Circle().trim(from: 0, to: NSDecimalNumber(decimal: remaining / total).doubleValue)
                        .stroke(accent.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: "wallet.pass").font(.system(size: 24)).foregroundStyle(accent)
            }.frame(width: 62, height: 62).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(balance?.isInitialGrantOnly == true ? "已知初始赠额" : "API 总额度").font(.caption).foregroundStyle(.secondary)
                Text(balance?.totalCredits.map { APIUsageFormat.compactMoney($0, currency: balance!.currency) } ?? "待核实")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(balance?.isInitialGrantOnly == true ? "初始金额 · 非当前余额" : "核对记录 · 不随周期变化").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 58)
            VStack(alignment: .leading, spacing: 6) {
                Text("剩余额度").font(.caption).foregroundStyle(.secondary)
                Text(balance?.remainingCredits.map { APIUsageFormat.compactMoney($0, currency: balance!.currency) } ?? "待核实")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(accent)
                if let balance {
                    Text("\(balance.verifiedAt.formatted(date: .numeric, time: .shortened)) 核对")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("以官方 Credit grants 为准").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 10) {
                Button("核对额度") { showsBalanceEditor = true }.buttonStyle(.bordered)
                Link("查看官方赠额 ↗", destination: URL(string: "https://platform.openai.com/settings/organization/billing/credit-grants")!)
                    .font(.caption)
            }
        }.padding(22)
            .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.12), lineWidth: 1))
    }

    private var creditsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            balanceCard
            HStack(alignment: .top, spacing: 18) {
                expiryCard.frame(width: 245)
                APIDashboardCard {
                    Label("本机到期提醒", systemImage: "bell.badge").font(.headline)
                    Toggle("启用提醒", isOn: Binding(get: { model.configuration.remindersEnabled }, set: { enabled in
                        Task { await model.setReminders(enabled) }
                    })).toggleStyle(.switch)
                    Text(model.reminderStatus).font(.callout).foregroundStyle(.secondary)
                    Text("仅日期：提前 3 / 1 天 09:00（北京时间）\n精确时间：提前 7 / 3 / 1 天")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                    if let account { Button("设置到期日期") { expiryEditor = account } }
                }
            }
            APIDashboardCard {
                HStack {
                    Label("赠额记录", systemImage: "ticket").font(.headline)
                    Spacer()
                    Button("添加批次", systemImage: "plus") { grantEditor = GrantEditorTarget(grant: nil) }
                }
                Text("记录发放金额与有效期，剩余额请以官方账单为准。").font(.callout).foregroundStyle(.secondary)
                if model.grants.isEmpty { smallEmpty("还没有精确批次", subtitle: "已知日期可单独设置提醒", icon: "gift") }
                ForEach(model.grants) { grant in
                    Divider().padding(.vertical, 4)
                    HStack(alignment: .top) {
                        Image(systemName: "gift.fill").font(.title2).foregroundStyle(.orange).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(APIUsageFormat.amount(grant.amount, currency: grant.currency)).font(.title3.weight(.semibold))
                            Text("到期：\(APIUsageFormat.date(grant.expiresAt))").font(.callout)
                            Text("发放：\(APIUsageFormat.date(grant.issuedAt))").font(.caption).foregroundStyle(.secondary)
                            Text("\(grant.source) · 核对于 \(APIUsageFormat.date(grant.verifiedAt))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("管理") {
                            Button("编辑批次") { grantEditor = GrantEditorTarget(grant: grant) }
                            Button("设为统计周期") {
                                do { try model.useGrantPeriod(grant); page = "overview" } catch { model.message = error.localizedDescription }
                            }.disabled(model.isDemo)
                            Button("删除", role: .destructive) { Task { await model.deleteGrant(grant.id) } }
                        }.fixedSize()
                    }
                }
                if let account {
                    DisclosureGroup("账号记录") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(account.creditNote)
                            Text(account.credentialNote)
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
            }
            Text("已排程提醒由 macOS 投递，受通知设置、专注模式、休眠和关机影响。批次变更与后台同步需要应用运行。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detailsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("数据明细与统计口径").font(.title2.bold()); Spacer(); Button("完成") { showsDetails = false }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let org = model.organization {
                        Text("\(org.name)\n\(org.id)\n\(org.projectID ?? "全部项目（包含未归属项目）")")
                            .font(.callout.monospaced()).textSelection(.enabled)
                    }
                    Text("费用包含全部能力；请求与 Token 仅覆盖 Responses / Chat Completions。缓存输入已包含在输入 Token 中。费用不是赠额余额，未自动抵扣手工赠额。")
                        .font(.callout).foregroundStyle(.secondary)
                    reportDetail("周期费用", report: model.snapshot?.cycle)
                    if let range = model.snapshot?.cycle.value?.bucketRange {
                        Text("实际完整日桶：\(APIUsageFormat.date(range.start)) → \(APIUsageFormat.date(range.end))\n边界外的完整 UTC 日桶可能被包含；不按小时拆分。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    reportDetail("今日费用", report: model.snapshot?.today)
                    ForEach((model.snapshot?.today.value?.totals ?? [:]).keys.sorted(), id: \.self) { currency in
                        Text(APIUsageFormat.amount(model.snapshot!.today.value!.totals[currency]!, currency: currency))
                    }
                    Divider()
                    reportDetail("模型用量", report: model.snapshot?.usage)
                    ForEach(model.snapshot?.usage.value?.models ?? []) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.model).fontWeight(.semibold)
                            Text(row.projectID ?? "未归属项目").font(.caption).foregroundStyle(.secondary)
                            Text("请求 \(row.requests.formatted()) · 输入 \(row.inputTokens.formatted()) · 输出 \(row.outputTokens.formatted()) · 缓存输入 \(row.cachedInputTokens.formatted())")
                                .font(.caption).monospacedDigit()
                        }
                    }
                    Divider()
                    Text("官方费用条目").font(.headline)
                    ForEach(Array((model.snapshot?.cycle.value?.lines ?? []).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(line.lineItem ?? "未归属条目")
                                Text(line.projectID ?? "未归属项目").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(APIUsageFormat.amount(line.amount, currency: line.currency)).monospacedDigit()
                        }.font(.caption)
                    }
                }.textSelection(.enabled)
            }
        }.padding(28).frame(width: 720, height: 620)
    }

    @ViewBuilder private func reportDetail<T>(_ title: String, report: APIReport<T>?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let report {
                Text("\(APIUsageFormat.date(report.range.start)) → \(APIUsageFormat.date(report.range.end))")
                if let fetched = report.fetchedAt { Text("更新：\(APIUsageFormat.date(fetched))") }
                if let error = report.error { Text(error).foregroundStyle(.orange) }
            } else { Text("等待同步") }
        }.font(.caption)
    }

    private var accountSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("登记跟踪账号").font(.title2.weight(.semibold))
            TextField("账号名称", text: $accountName).textFieldStyle(.roundedBorder)
            Text("可先登记账号，稍后连接组织账单。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("取消") { showsAccountEditor = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("登记") {
                    do {
                        try model.registerAccount(name: accountName, credentialNote: "待提供组织 ID 与 Admin API Key。",
                                                  creditNote: "赠额金额及精确到期时间待核实；未建立提醒。")
                        showsAccountEditor = false; accountName = ""
                    } catch { model.message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 460)
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.callout).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
    private func smallEmpty(_ title: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary.opacity(0.6))
            Text(title).font(.callout.weight(.medium))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

private struct APIDashboardCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.05), lineWidth: 1))
    }
}

private struct APICostTrendCard: View {
    let report: APIReport<APICostSummary>?
    @State private var currency = "USD"
    @State private var selectedDate: Date?
    private var currencies: [String] { report?.value?.totals.keys.sorted() ?? [] }
    private var selectedCurrency: String { currencies.contains(currency) ? currency : (currencies.first ?? "USD") }
    // Absent currency/day is unknown, never a manufactured zero.
    private var days: [APICostDay] { (report?.value?.days ?? []).filter { $0.totals[selectedCurrency] != nil } }
    private var selectedDay: APICostDay? {
        guard let selectedDate else { return nil }
        return days.min { abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate)) }
    }
    var body: some View {
        APIDashboardCard {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("费用趋势").font(.headline)
                    Text("每日费用 · \(selectedCurrency) · UTC").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let day = selectedDay, let amount = day.totals[selectedCurrency] {
                    Text("\(APIUsageFormat.utcDay(day.start))  ·  \(APIUsageFormat.amount(amount, currency: selectedCurrency))")
                        .font(.caption.monospacedDigit())
                }
                if currencies.count > 1 {
                    Picker("币种", selection: $currency) { ForEach(currencies, id: \.self) { Text($0).tag($0) } }.frame(width: 90)
                }
            }
            if days.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.indigo.opacity(0.55))
                    Text(report?.value == nil ? "等待账单数据" : "这个周期暂无趋势数据").font(.callout.weight(.medium))
                    Text(report?.value?.days == nil && report?.value != nil ? "刷新后载入逐日费用" : "试试近 30 天，或选择其他日期")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 180)
            } else {
                Chart(days) { day in
                    let amount = NSDecimalNumber(decimal: day.totals[selectedCurrency]!).doubleValue
                    BarMark(x: .value("UTC 日期", APIUsageFormat.utcDayKey(day.start)), y: .value("费用", amount),
                            width: .fixed(min(24, 325 / Double(max(1, days.count)))))
                        .foregroundStyle(Color.indigo.gradient).cornerRadius(3)
                        .accessibilityLabel(APIUsageFormat.utcDay(day.start))
                        .accessibilityValue(APIUsageFormat.amount(day.totals[selectedCurrency]!, currency: selectedCurrency))
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXAxis {
                    AxisMarks(values: axisDays) { value in
                        AxisGridLine(); AxisTick()
                        AxisValueLabel { if let label = value.as(String.self) { Text(String(label.suffix(5))) } }
                    }
                }
                .frame(height: 180)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point):
                                    if let frame = proxy.plotFrame {
                                        let x = point.x - geometry[frame].origin.x
                                        if let label: String = proxy.value(atX: x) {
                                            selectedDate = days.first { APIUsageFormat.utcDayKey($0.start) == label }?.start
                                        }
                                    }
                                case .ended: selectedDate = nil
                                }
                            }
                    }
                }
            }
        }
    }
    private var axisDays: [String] {
        let step = max(1, Int(ceil(Double(days.count) / 7)))
        return days.enumerated().filter { $0.offset % step == 0 }.map { APIUsageFormat.utcDayKey($0.element.start) }
    }
}

private struct APICreditBalanceEditor: View {
    @ObservedObject var model: APIUsageModel
    @Environment(\.dismiss) private var dismiss
    @State private var total = ""
    @State private var remaining = ""
    @State private var currency = "USD"
    @State private var initialOnly = false
    @State private var source = "官方 Credit grants"
    @State private var verifiedAt = Date()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("核对 API 额度", systemImage: "wallet.pass").font(.title2.weight(.semibold))
            Text("依据官方赠额／余额页面填写。月度花费上限不是额度；未知的金额留空。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField(initialOnly ? "已知初始赠额" : "总额度", text: $total, prompt: Text("待核实可留空"))
                TextField("剩余额度", text: $remaining, prompt: Text("待核实可留空"))
                TextField("币种", text: $currency)
                Toggle("只确认了初始赠额，未核实总额度", isOn: $initialOnly)
                TextField("核对来源", text: $source)
                DatePicker("核对时间", selection: $verifiedAt, in: ...Date())
            }.textFieldStyle(.roundedBorder)
            Text("这是带时间的账单记录；不会用所选周期的费用推算余额，也不会自动随接口刷新改变。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存核对结果") {
                    do {
                        let balance = APICreditBalance(totalCredits: try parse(total), remainingCredits: try parse(remaining),
                            currency: currency.uppercased(), isInitialGrantOnly: initialOnly, source: source, verifiedAt: verifiedAt)
                        try model.saveCreditBalance(balance); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 520)
        .onAppear {
            if let value = model.creditBalance {
                total = value.totalCredits?.description ?? ""; remaining = value.remainingCredits?.description ?? ""
                currency = value.currency; initialOnly = value.isInitialGrantOnly; source = value.source; verifiedAt = value.verifiedAt
            }
        }
    }
    private func parse(_ input: String) throws -> Decimal? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return nil }
        guard input.range(of: #"^(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")) else { throw APIUsageError.invalidGrant }
        return value
    }
}

private struct APIPeriodEditor: View {
    @ObservedObject var model: APIUsageModel
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date().addingTimeInterval(-6 * 86_400)
    @State private var end = Date()
    @State private var error: String?
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("自定义统计周期", systemImage: "calendar").font(.title2.weight(.semibold))
            Text("选择包含首尾两天的日期范围，按 UTC 账单日查询。").font(.callout).foregroundStyle(.secondary)
            DatePicker("开始日期", selection: $start, in: ...Date(), displayedComponents: .date)
            DatePicker("结束日期", selection: $end, in: ...Date(), displayedComponents: .date)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用周期") {
                    do {
                        let from = calendar.startOfDay(for: start)
                        let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
                        guard from <= calendar.startOfDay(for: end) else { error = "结束日期不能早于开始日期。"; return }
                        guard to.timeIntervalSince(from) <= 366 * 86_400 else { error = "单次查询最多 366 天。"; return }
                        try model.setPeriod(APIPeriodSelection(preset: .custom, customRange: APIQueryRange(start: from, end: to)))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 460)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .onAppear {
            if let org = model.organization {
                let range = model.period.range(organization: org, now: Date())
                start = range.start; end = range.end.addingTimeInterval(-1)
            }
        }
    }
}

extension APIUsageFormat {
    static func compactNumber(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value).doubleValue
        if number >= 1_000_000 { return (number / 1_000_000).formatted(.number.precision(.fractionLength(0...2))) + "M" }
        if number >= 1_000 { return (number / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "K" }
        return number.formatted(.number.precision(.fractionLength(0)))
    }
    static func compactMoney(_ value: Decimal, currency: String) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = value != 0 && abs(NSDecimalNumber(decimal: value).doubleValue) < 0.01 ? 6 : 2
        let text = formatter.string(from: NSDecimalNumber(decimal: value)) ?? value.description
        if value != 0 && NSDecimalNumber(decimal: value).doubleValue.magnitude < 0.000001 { return amount(value, currency: currency) }
        return (currency == "USD" ? "$" : currency + " ") + text
    }
    static func utcDayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"; return formatter.string(from: date)
    }
    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM/dd"; return formatter.string(from: date)
    }
    static func rangeLabel(_ range: APIQueryRange) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return "\(formatter.string(from: range.start)) – \(formatter.string(from: range.end)) UTC"
    }
}
private struct OrganizationEditorTarget: Identifiable {
    let id = UUID()
    var organization: APIOrganization?
    var accountID: UUID? = nil
}
private struct GrantEditorTarget: Identifiable {
    let id = UUID()
    var grant: APICreditGrant?
}

private struct APIOrganizationEditor: View {
    @ObservedObject var model: APIUsageModel
    let existing: APIOrganization?
    var accountID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var name = ""
    @State private var project = ""
    @State private var start = ""
    @State private var end = ""
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "添加 API 组织" : "组织与连接设置").font(.title2.weight(.semibold))
            Text("使用有账单读取权限的专用 Admin API Key。普通项目调用 Key 和 Codex 登录凭据不能替代。密钥只存于此 Mac 的 Keychain。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("组织 ID", text: $id, prompt: Text("org-…")).disabled(existing != nil)
                TextField("显示名称", text: $name)
                TextField("项目 ID（可选）", text: $project, prompt: Text("proj_…；留空为全部项目"))
                TextField("周期起点", text: $start)
                TextField("周期终点", text: $end)
                SecureField(existing == nil ? "Admin API Key" : "更换密钥（留空保留）", text: $key, prompt: Text("sk-admin-…"))
            }.textFieldStyle(.roundedBorder)
            Text("时间格式：2027-01-15T23:59:59+08:00，必须包含时区。可按赠额实际有效期设置，未来终点查询到刷新时刻。")
                .font(.caption).foregroundStyle(.secondary)
            Link("在官方平台创建 Admin Key", destination: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("取消") { key = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存并刷新", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600)
        .onAppear {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            let month = calendar.dateInterval(of: .month, for: Date())!
            id = existing?.id ?? ""; name = existing?.name ?? ""; project = existing?.projectID ?? ""
            start = APIUsageFormat.iso(existing?.cycleStart ?? month.start)
            end = APIUsageFormat.iso(existing?.cycleEnd ?? month.end)
        }
    }
    private func save() {
        do {
            guard let from = APIUsageFormat.parse(start), let to = APIUsageFormat.parse(end) else {
                throw APIUsageError.invalidConfiguration
            }
            try model.saveOrganization(APIOrganization(id: id, name: name, projectID: project, cycleStart: from, cycleEnd: to), key: key, accountID: accountID)
            key = ""; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct APICreditEditor: View {
    @ObservedObject var model: APIUsageModel
    let organizationID: String
    let existing: APICreditGrant?
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var currency = "USD"
    @State private var issued = ""
    @State private var expires = ""
    @State private var source = ""
    @State private var verified = ""
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "添加赠额批次" : "编辑赠额批次").font(.title2.weight(.semibold))
            Text("记录已核对的发放金额和有效期；此记录不代表官方剩余额。").foregroundStyle(.secondary)
            Form {
                TextField("金额", text: $amount, prompt: Text("例如 50.00"))
                TextField("币种", text: $currency)
                TextField("发放时间", text: $issued)
                TextField("精确到期时间", text: $expires)
                TextField("来源", text: $source, prompt: Text("例如官方账单／邮件的标题"))
                TextField("核对时间", text: $verified)
            }.textFieldStyle(.roundedBorder)
            Text("时间格式：2027-01-15T23:59:59+08:00；也接受带 Z 的 UTC 时间。请依据官方账单填写，不猜测当天的到期时刻。显示默认北京时间。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { Task { await save() } }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(24).frame(width: 600)
        .onAppear {
            amount = existing?.amount.description ?? ""; currency = existing?.currency ?? "USD"
            source = existing?.source ?? ""
            issued = APIUsageFormat.iso(existing?.issuedAt ?? Date())
            // An unknown expiry must be entered deliberately.
            expires = existing.map { APIUsageFormat.iso($0.expiresAt) } ?? ""
            verified = APIUsageFormat.iso(existing?.verifiedAt ?? Date())
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            guard amount.range(of: #"^(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")),
                  let issuedAt = APIUsageFormat.parse(issued), let expiresAt = APIUsageFormat.parse(expires),
                  let verifiedAt = APIUsageFormat.parse(verified) else { throw APIUsageError.invalidGrant }
            try await model.saveGrant(APICreditGrant(id: existing?.id ?? UUID(), organizationID: organizationID,
                                                     amount: value, currency: currency, issuedAt: issuedAt,
                                                     expiresAt: expiresAt, source: source, verifiedAt: verifiedAt))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
