import AppKit
import SwiftUI
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.isDemo {
                        Label("演示模式 · 所有金额、模型与组织均为合成数据；不连接网络、不保存密钥。", systemImage: "testtube.2")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if let message = model.message {
                        HStack(alignment: .top) {
                            Label(message, systemImage: "info.circle")
                            Spacer()
                            Button("关闭提示", systemImage: "xmark") { model.message = nil }.labelStyle(.iconOnly)
                        }.font(.callout).padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let organization = model.organization {
                        scope(organization)
                        HStack(alignment: .top, spacing: 16) {
                            costCard("今日 API 费用", report: model.snapshot?.today)
                            costCard("本周期 API 费用", report: model.snapshot?.cycle)
                        }
                        usageCard
                        creditsCard
                    } else {
                        ContentUnavailableView {
                            Label("连接 API 组织账单", systemImage: "chart.bar.doc.horizontal")
                        } description: {
                            Text("添加组织 ID 和专用 Admin API Key，读取官方费用与用量。Codex 订阅配额与 API 账单独立，请在账号切换器中查看。")
                        } actions: {
                            Button("添加组织") { organizationEditor = OrganizationEditorTarget(organization: nil) }
                                .buttonStyle(.borderedProminent)
                        }.padding(.vertical, 36)
                    }
                    Text("账单数据可能延迟。费用来自官方 Costs；请求与 token 仅覆盖 Responses／Chat Completions（含缓存 token）。图像、音频、嵌入、工具与存储等能力的请求量未单独统计，其账单费用包含在 Costs 明细中。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Link("打开官方账单核对", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
                        Spacer()
                        Text("API 账单与 Codex 订阅配额独立").foregroundStyle(.secondary)
                    }.font(.caption)
                }.padding(24)
            }
        }
        .frame(minWidth: 820, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $organizationEditor) { target in
            APIOrganizationEditor(model: model, existing: target.organization)
        }
        .sheet(item: $grantEditor) { target in
            if let org = model.organization { APICreditEditor(model: model, organizationID: org.id, existing: target.grant) }
        }
        .confirmationDialog("移除组织及其全部本地记录？", isPresented: $showsRemoval) {
            Button("移除组织、密钥、缓存与赠额记录", role: .destructive) {
                Task {
                    do { try await model.removeOrganization() }
                    catch { model.message = error.localizedDescription }
                }
            }
        } message: { Text("会取消该组织的待发送提醒，不修改 OpenAI 官方账单或组织配置。") }
        .task { model.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("API 用量与赠额").font(.title2.weight(.semibold))
                Text("官方组织统计 · 本机赠额记录").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.organization != nil {
                Picker("组织", selection: Binding(get: { model.configuration.selectedID ?? "" }, set: model.select)) {
                    ForEach(model.configuration.organizations) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 200)
                Button {
                    model.refresh()
                } label: {
                    if model.isRefreshing { ProgressView().controlSize(.small) }
                    else { Label("刷新", systemImage: "arrow.clockwise") }
                }.disabled(model.isRefreshing || model.isDemo).help("应用运行时每 15 分钟刷新；不会切换 Codex 账号")
            }
            Menu {
                Button("添加组织") { organizationEditor = OrganizationEditorTarget(organization: nil) }
                if model.organization != nil {
                    Button("组织与连接设置") { organizationEditor = OrganizationEditorTarget(organization: model.organization) }
                    Button("断开并清理此组织密钥") {
                        do { try model.disconnect() } catch { model.message = error.localizedDescription }
                    }
                    Button("移除此组织…", role: .destructive) { showsRemoval = true }
                }
            } label: { Label("设置", systemImage: "gearshape") }.fixedSize().disabled(model.isDemo)
        }.padding(20)
    }

    private func scope(_ organization: APIOrganization) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(organization.name).font(.headline)
            Text("\(organization.id)  ·  \(organization.projectID ?? "全部项目（包含未归属项目）")")
                .font(.callout.monospaced()).textSelection(.enabled)
            Text("统计周期：\(APIUsageFormat.date(organization.cycleStart)) → \(APIUsageFormat.date(organization.cycleEnd))")
                .font(.caption).foregroundStyle(.secondary)
            Text("今日按北京时间划分；查询截止至刷新时刻，区间含起点、不含终点。组织只统计一次，不随 Codex 账号切换。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func costCard(_ title: String, report: APIReport<APICostSummary>?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if report?.error != nil, report?.value != nil {
                Text("显示上次成功缓存，以下方范围为准").font(.caption).foregroundStyle(.orange)
            }
            if let value = report?.value {
                if value.totals.isEmpty {
                    Text("官方未返回费用条目").font(.title3)
                    Text("不代表赠额余额为零").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(value.totals.keys.sorted(), id: \.self) { currency in
                        Text(APIUsageFormat.amount(value.totals[currency]!, currency: currency))
                            .font(.title2.weight(.semibold)).monospacedDigit().textSelection(.enabled)
                    }
                }
            } else { Text("未连接／待核验").font(.title3).foregroundStyle(.secondary) }
            reportStatus(report).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func reportStatus<T>(_ report: APIReport<T>?) -> some View {
        if let report {
            if let error = report.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let fetched = report.fetchedAt {
                Text("\(report.isStale(now: Date()) ? "缓存已过期 · " : "")更新：\(APIUsageFormat.date(fetched))")
            }
            Text("范围：\(APIUsageFormat.date(report.range.start)) → \(APIUsageFormat.date(report.range.end))")
        } else { Text("连接后显示查询范围与最后刷新时间") }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("本周期模型用量").font(.headline)
            if let usage = model.snapshot?.usage.value {
                HStack(spacing: 28) {
                    metric("请求", values: usage.models.map(\.requests))
                    metric("输入 token", values: usage.models.map(\.inputTokens))
                    metric("输出 token", values: usage.models.map(\.outputTokens))
                    metric("缓存输入（已含在输入中）", values: usage.models.map(\.cachedInputTokens))
                }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                    GridRow {
                        Text("模型／项目"); Text("请求"); Text("输入 token"); Text("输出 token")
                    }.fontWeight(.medium).foregroundStyle(.secondary)
                    ForEach(usage.models) { row in
                        Divider()
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(row.model).textSelection(.enabled)
                                Text(row.projectID ?? "未归属项目").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.requests.formatted()); Text(row.inputTokens.formatted()); Text(row.outputTokens.formatted())
                        }.monospacedDigit()
                    }
                }.font(.callout)
                if usage.models.isEmpty { Text("官方未返回此范围内的模型用量条目。").foregroundStyle(.secondary) }
            } else { Text("用量未连接／待核验").foregroundStyle(.secondary) }
            reportStatus(model.snapshot?.usage).font(.caption).foregroundStyle(.secondary)
            if let costs = model.snapshot?.cycle.value, !costs.lines.isEmpty {
                DisclosureGroup("查看官方费用条目（全部能力）") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(costs.lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) {
                                    Text(line.lineItem ?? "未归属条目")
                                    Text(line.projectID ?? "未归属项目").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(APIUsageFormat.amount(line.amount, currency: line.currency)).monospacedDigit()
                            }
                        }
                    }.font(.caption).padding(.top, 8)
                }
            }
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ title: String, values: [Int64]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(values.reduce(Decimal.zero) { $0 + Decimal($1) }.description).font(.title3.weight(.medium)).monospacedDigit()
        }
    }

    private var creditsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("赠额批次").font(.headline)
                Spacer()
                Button("添加赠额", systemImage: "plus") { grantEditor = GrantEditorTarget(grant: nil) }
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("官方余额：待核验").fontWeight(.medium)
                    Text("尚无已确认的公开赠额余额／批次 API，请到官方账单核对。")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地剩余额估算：未计算").fontWeight(.medium)
                    Text("手工批次金额不代表当前余额；不自动抵扣费用或滚存到下周期。")
                }
            }.font(.callout).foregroundStyle(.secondary)
            ForEach(model.grants) { grant in
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(APIUsageFormat.amount(grant.amount, currency: grant.currency)).fontWeight(.semibold).monospacedDigit()
                            Text(grant.isActive(at: Date()) ? "有效期内" : (Date() < grant.issuedAt ? "尚未发放" : "已到期"))
                                .font(.caption).foregroundStyle(grant.isActive(at: Date()) ? .green : .secondary)
                        }
                        Text("发放：\(APIUsageFormat.date(grant.issuedAt))")
                        Text("到期：\(APIUsageFormat.date(grant.expiresAt))").fontWeight(.medium)
                        Text("来源：\(grant.source) · 核对：\(APIUsageFormat.date(grant.verifiedAt))").foregroundStyle(.secondary)
                    }.font(.caption).textSelection(.enabled)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Button("编辑") { grantEditor = GrantEditorTarget(grant: grant) }
                        Button("设为统计周期") {
                            do { try model.useGrantPeriod(grant) } catch { model.message = error.localizedDescription }
                        }.disabled(model.isDemo)
                        Button("删除", role: .destructive) { Task { await model.deleteGrant(grant.id) } }
                    }.font(.caption)
                }
            }
            if model.grants.isEmpty { Text("录入官方账单或邮件中已核对的批次；请包含时区和精确到秒的到期时间。").foregroundStyle(.secondary) }
            Divider()
            Toggle("到期前 7／3／1 天本机提醒", isOn: Binding(
                get: { model.configuration.remindersEnabled }, set: { value in Task { await model.setReminders(value) } }))
                .toggleStyle(.switch)
            Text("仅主动开启时请求通知权限。每个批次按精确到期时刻提前 7／3／1 个 24 小时排程；发放前或已错过的提醒不补发。最多预排最近 60 条，新增和修改排程、后台刷新需应用运行。已排程通知由 macOS 投递，受系统通知设置、专注模式、休眠和关机影响，不保证准时送达。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct OrganizationEditorTarget: Identifiable {
    let id = UUID()
    var organization: APIOrganization?
}
private struct GrantEditorTarget: Identifiable {
    let id = UUID()
    var grant: APICreditGrant?
}

private struct APIOrganizationEditor: View {
    @ObservedObject var model: APIUsageModel
    let existing: APIOrganization?
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
            try model.saveOrganization(APIOrganization(id: id, name: name, projectID: project, cycleStart: from, cycleEnd: to), key: key)
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
