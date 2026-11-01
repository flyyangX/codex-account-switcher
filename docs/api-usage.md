# Mac API 用量、费用与赠额提醒

此功能属于 `flyyangX/codex-account-switcher` fork 的本地开发版本。上游项目由刘朝（Zhao Liu，`liuzhao1225`）创建，MIT 许可与版权保留。本文示例全部为合成数据。

## 启动与连接

运行 `./scripts/package-api-monitor.sh`，打开脚本最后输出的 `Codex API Monitor.app`。实际目录由 `swift build -c release --show-bin-path` 决定（本机为 `.build/out/Products/Release/`）。这个包使用独立名称和 Bundle ID `com.flyyang.codex-api-monitor`，不安装或覆盖已有应用，不连接上游 Sparkle 更新源。API 窗口默认打开，也可从菜单栏的“API 用量与赠额”进入。

1. 点击“添加组织”，填写官方组织 ID（`org-…`）、名称和可选项目 ID（`proj_…`）。留空项目表示整个组织，包括未归属项目的费用。
2. 设置统计周期。默认提供北京时间自然月，可改成任意有效区间（最长 366 天），或在赠额批次上点击“设为统计周期”。周期未来终点查询到刷新时刻；尚未开始的周期显示不可用。
3. 在 [OpenAI 官方平台](https://platform.openai.com/settings/organization/admin-keys)创建有相应读取权限的专用 Admin API Key，在界面的安全输入框保存。普通项目调用 Key 和 Codex 登录凭据不能替代。每个组织只保留一份配置和一项凭据，再次保存同一 ID 会更新配置，不按 Codex 账号重复汇总。
4. 点击“刷新”。应用启动和运行时每 15 分钟刷新当前选中的组织；切换组织会刷新对应统计。网络错误不会连续重试。

只有 GET 请求会发送到固定官方域名，拒绝重定向。不会调用模型、切换 Codex 账号或修改官方组织。此独立包专注 API 窗口与独立菜单，不读取现有 Codex 凭据、不启动 Codex 配额刷新。源码中的普通 Account Switcher 构建保留原有账号操作和新增的 API 入口。

## 指标与数据边界

| 显示 | 来源与含义 |
| --- | --- |
| 今日费用 | 官方 `/v1/organization/costs`，北京时间当天起点至刷新时刻 |
| 本周期费用 | 官方 Costs，配置的实际区间至刷新时刻；按官方币种分别求和，保留退款负数，不用 token 价格估算 |
| 请求、输入／输出 token、模型分布 | `/v1/organization/usage/completions`，覆盖 Responses／Chat Completions；缓存输入已包含在输入 token 中，不再重复相加 |
| 费用明细 | Costs 按 `project_id` 和 `line_item` 分组，包含接口返回的全部计费能力，不局限于 completions |
| 官方赠额余额 | 待核验；本次查阅的公开文档没有建立可确认的促销赠额余额／批次接口 |
| 本地剩余额估算 | 首版不计算。多批赠额、混合付费、退款和缺失数据无法从总费用准确还原赠额抵扣顺序 |

每项统计显示实际查询范围和独立的最后成功刷新时间。起点包含、终点不包含，存储和请求以 Unix 时间为准。金额在解码、计算和存储中使用 `Decimal`，界面保留小额费用的有效数字，不把极小金额四舍五入为零。

Usage 与 Costs 均遍历 `has_more`／`next_page`。任一页失败、游标循环、重复桶、必要金额字段缺失或项目归属不符，整项结果不可用，不接受部分汇总。官方日桶若超出精确查询边界，不能按比例拆分日费用：界面会显示范围不可用并指向官方账单。真实组织对任意时间边界的返回行为尚待连接验收。

401、403、限流、服务端失败和网络错误分别显示。已有成功数据会保留原范围和时间，错误或超过 30 分钟标为过期。无成功结果时显示“未连接／待核验”。官方返回空条目时显示“未返回费用条目”，不解释为赠额余额为零。账单数据可能存在延迟。

首版不单独统计嵌入、图像、音频、工具或存储的请求量；这些能力的费用仍通过 Costs 明细展示。没有实现 Windows API 界面或修改 Windows Host 协议。

## 赠额记录与提醒

批次包含金额、币种、组织、发放时间、精确到期时间、来源和核对时间。时间输入采用带时区的 ISO 8601，例如 `2030-05-10T23:59:59+08:00`；本地存储保留绝对时间和毫秒精度，默认北京时间显示到秒。不知道精确到期时刻时应先核对官方账单，不猜测当天午夜。

有效区间为 `[发放时间, 到期时间)`，到期后不滚入下一批。“有效期内”仅指时间状态，不表示还有可用余额。批次金额和费用始终分开显示。

“到期前 7／3／1 天本机提醒”默认关闭，只有主动开启才请求 macOS 通知权限。提醒按到期时刻提前 7／3／1 个 24 小时排程；发放前和已经错过的时点不补发。稳定标识符避免重复，编辑到期时间或删除记录会重排／撤销待发送提醒。移除组织会同时清理该组织的凭据、缓存、手工批次和待发送提醒。普通“断开”仅清理凭据与账单缓存，保留手工批次及其提醒。

最多预排最近 60 条，其余在应用运行时的后续刷新中补排。新增／修改排程和后台读取需应用运行；已经排程的本地通知交由 macOS 投递。权限、系统通知设置、专注模式、休眠与关机会影响实际显示，不保证电脑关闭时仍准时提醒。本地 ad-hoc 签名包尚未公证；权限弹窗和跨重启实际投递需在用户启用后验收。

## 本机数据与凭据

- 配置与缓存：`~/Library/Application Support/Codex API Monitor/API Usage/`，目录 `0700`、文件 `0600`，原子替换。
- Admin Key：仅在本机 Keychain，独立 service `com.flyyang.codex-api-monitor.admin-key`，不参与 iCloud 同步，仅本设备解锁时可读。界面不回显已保存密钥。
- 配置、缓存、导出、日志与 Codex `auth.json` 不保存此功能的 Admin Key；本功能没有导出或诊断上传接口。
- 设置中的“断开并清理此组织密钥”删除该组织 Keychain 项与账单缓存，不代表吊销官方 Key；如需吊销，应在官方平台操作。文件删除不承诺擦除 APFS 快照或外部备份。
- 独立包的 Codex profile 目录为 `Codex API Monitor/Accounts/`。原有账号切换行为和权限边界保留；API 数据读取与其分离。

## 开发验证

```sh
swift build
swift test
./scripts/run-core-checks.sh
node scripts/check-site-geo.mjs
node --test scripts/tests/*.test.mjs
./scripts/package-api-monitor.sh
open "$(swift build -c release --show-bin-path)/Codex API Monitor.app" --args --api-demo
```

`--api-demo` 仅显示合成数据，阻止网络刷新、Keychain 写入、持久化和通知权限请求，便于本地界面检查。模型与客户端测试使用临时目录、内存凭据和合成 HTTP 响应，不读取真实凭据或消费额度。

测试覆盖金额／币种／退款、分页与参数归属、权限／接口／网络失败、时间边界、缓存过期和保留、批次有效期和提醒标识、重复组织、断开清理及配置不含密钥。真实账单权限、平台延迟、Mac 通知权限弹窗与最终投递仍需用户在成品连接后验证；本地构建不等于生产发布或员工／客户验收。

可选的本机 Keychain 集成检查：`SWITCHER_TEST_KEYCHAIN=1 swift test --filter APIUsageModelTests`。仅创建、读取、替换和删除随机组织 ID 下的合成测试项，结束后清理，不读取已有组织密钥；默认不在 CI 或锁定钥匙串环境执行。

### 本次本地验证结果

- `swift build`、release 构建和 ad-hoc 包签名核验通过。
- 最终 `swift test` 输出共享核心 82 项、Mac 58 项、共 18 个 suite 通过；保留上游按环境跳过的 RPC fixture／installed CLI 检查、未安装 fish 的检查，以及默认关闭的 Keychain 集成项。没有将这些跳过项视为已验收。
- 显式启用 Keychain 后，API 模型的 6 项测试通过，包括系统 Keychain 的合成项写入、读取、替换和删除。
- `run-core-checks.sh`、网站一致性检查和 25 项 Node 脚本测试通过。
- Mac 真机正常模式：未连接空状态、组织配置与安全密钥字段、取消返回正常，未保存组织或密钥。
- Mac 真机演示模式：金额／查询范围／模型列表、赠额编辑、新增删除、UTC 转北京时间、提醒不请求权限，以及关闭窗口后重新打开 `.app` 恢复窗口已验证。
- 菜单栏图标的直接点击重开因当前 UI 工具无法读取无窗口菜单栏而未验证；可通过再次打开 `.app` 恢复窗口。真实账单、通知权限弹窗和最终投递、Windows 运行时仍未验收。没有正式发布。

## 官方依据（2026-11-01 核对）

- [组织管理与 Admin Key](https://developers.openai.com/api/docs/guides/admin-apis)
- [Costs API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs)
- [Completions Usage API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/completions)
- [ChatGPT 订阅赠额说明](https://developers.openai.com/api/docs/guides/chatgpt-api-credits)
- [Apple 本地通知排程](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)

赠额活动资格、适用范围和续订规则可能变化，以官方账单和当前活动条款为准。此应用不承诺活动资格，也不将 API 赠额解释为 Codex 订阅配额。
