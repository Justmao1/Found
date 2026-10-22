# iPad 原生客户端

[返回总览](README.md) · 更新：2026-10-22。依据当前 Swift 源码，部署与测试范围另见[验证文档](05-verification-roadmap.md)。

## 1. 定位与模块

App 是站点共用的英文界面，不是每位失主安装的个人账户 App。最低 iOS 17，使用 SwiftUI；iPad 为主要设备，iPhone 布局保留作兼容与测试。设备提供相机、麦克风和触控屏，站点后端地址由工作人员设置。

| 源文件 | 职责 |
| --- | --- |
| [AppStore.swift](../../Lost&Found/AppStore.swift) | MainActor/Observable 状态、上传、搜索、识别刷新、会话和格口恢复 |
| [Core/APIClient.swift](../../Lost&Found/Core/APIClient.swift) | URLSession、JSON、超时、错误映射、同源图片地址 |
| [Core/Models.swift](../../Lost&Found/Core/Models.swift) | 物品、识别、搜索和上传请求类型 |
| [Core/Lockers.swift](../../Lost&Found/Core/Lockers.swift) | 格口快照、操作与请求契约 |
| [Core/ServerAddress.swift](../../Lost&Found/Core/ServerAddress.swift) | 地址校验和规范化 |
| [Core/ItemCategory.swift](../../Lost&Found/Core/ItemCategory.swift) | 主标签与本地 SF Symbols 映射，不额外调用模型 |
| [UI/ReportEditorView.swift](../../Lost&Found/UI/ReportEditorView.swift) | 图片确认、上传回执、标签和存物过程 |
| [UI/VoiceInputController.swift](../../Lost&Found/UI/VoiceInputController.swift) | 录音、权限、中断、转写和取消 |
| [UI/LockerFlowView.swift](../../Lost&Found/UI/LockerFlowView.swift) | 四格状态、格口编号、实时门状态、物品完成确认和访客续办页 |
| [UI/StationHomeView.swift](../../Lost&Found/UI/StationHomeView.swift) | 登记／查找入口、可用格口和未完成格口步骤入口 |
| [UI/StaffAccessView.swift](../../Lost&Found/UI/StaffAccessView.swift) | 设备认证、工作人员检查与操作恢复 |

## 2. 访客操作

### 登记与存物

1. Home 点击 I found something 进入 Report，访客使用系统相机；相册导入放在 Staff 工具中。有未完成格口命令时，该入口先继续原格口步骤，见下文恢复规则。
2. 图片归正方向、最长边缩至 1600 像素、透明区域填白并转 JPEG。确认照片，输入最多 200 Unicode 码点的备注。
3. 保存时保留图片、备注和同一 `request_id`。正在上传时禁用重复保存、结束和修改；失败后重试发送相同内容。
4. HTTP 保存确认后立即显示照片已登记，标签在后台轮询更新。识别重试不会再次保存照片。
5. 当前登记页在有效标签就绪且格口服务启用后调用独立 `beginDeposit`，客户端先写入待处理命令，再发送请求。不是后端上传或识别接口直接开锁。失败时显示恢复/工作人员入口。
6. 显示指定格口，用户放入物品并关门。01／02 会自动显示门状态，确认按钮只在新鲜的关闭读数下可用；用户仍须点击 I’ve placed the item inside。服务器回复完成后显示 Item stored。

照片保存和实际入柜是两个状态，不把 Photo received 显示为 Item stored。当前首页在格口服务未启用、状态未获取或没有空闲格口时禁用新登记；有同一服务器的待处理格口命令时仍提供续办入口。相同物品照片再次作为新的登记提交允许产生不同记录，系统不自动合并外观相同物品。

### 查找与领取

1. Find 以麦克风为主入口，也可选择 Type instead。
2. 最长约 30 秒录音，转换为 16 kHz、单声道、16-bit PCM WAV。拒绝权限或录音失败时仍可键入。
3. 转写结果写入可编辑描述，最多 500 Unicode 码点，用户确认后才搜索。
4. 展示候选照片、标签和简短理由；无匹配与网络失败分别呈现。
5. 启用格口时浏览使用 `available=1` 的可领取记录。选择 stored 物品、确认领取，再发起 retrieve。
6. 收到开锁请求状态后，用户取物并关门，再点击 I’ve taken my item。01／02 同样要求新的关闭读数；服务器确认后标记 Item collected 并释放格口。单凭 AI 相似度不会开锁。

### 门状态与完成确认

01 的反馈输入为 BCM GPIO12（物理第 32 针），02 为 BCM GPIO18（物理第 12 针），均按 LOW＝已扣住、HIGH＝未扣住解释。iPad 根据服务器返回的 `door` 数据绑定格口，不在客户端硬编码 GPIO。03／04 尚无反馈输入，仍由用户点击包含 closed the door 的完整确认按钮。

| 当前读数 | 英文界面 | 完成按钮 |
| --- | --- | --- |
| 有效关闭 | Door closed，绿色勾选图标 | 可用，仍需确认物品已放入／取走 |
| 有效未关 | Door not closed，橙色门图标 | 禁用 |
| 正在获取或尚未稳定 | Checking the door… | 禁用 |
| 读取失败、数据缺失或过期 | Door status unavailable | 禁用，可检查连接或请工作人员处理 |

仅在 App 前台、当前操作为 `awaiting_confirmation` 且无需工作人员处理时，每次读取结束后约 1 秒再 GET 原 operation。客户端按请求发起时间判断读数有效期，达到 3 秒即失效；进入后台、切换访客或更换操作也会使旧读数失效。已经确认配置传感器的操作若随后缺少 `door` 数据，不会退回人工确认并放行。

门状态轮询不重发开锁命令、不更新访客活动时间、不持续刷新库存。后端在 `/complete` 中再次验证对应传感器；**关门本身不标记物品已存入／已领取，也不释放格口**。门锁反馈只能说明触点状态，不能证明物品已移动。接线、去抖及后端限制见[门反馈说明](../door-feedback.md)。

## 3. 网络约定

真机默认 `https://work123.local:8443`；模拟器默认 `http://127.0.0.1:8080`。模拟器 localhost 指 Mac，真机 localhost 指 iPad 自己。非本机地址必须用 HTTPS，并保留系统证书和域名验证。

APIClient 普通 GET/POST 超时 20 秒，识别、搜索和转写为 45 秒。所有 POST 发送 JSON、固定 Content-Length 和 `X-Requested-With: lost-found-box`。图片地址须与配置服务器具有相同 scheme、host、port；服务端返回外域 URL 不会被当作物品图片加载。

服务地址保存在 UserDefaults。有上传或格口待处理操作时禁止切换服务器，以免把重试发送到另一台设备。切换成功后清除旧列表和导航，旧响应不能覆盖新服务器状态。

## 4. 会话与持久化

`visitorRevision`、服务器 `revision` 和刷新序号隔离异步结果。拍照导入、搜索、上传回调和格口按钮应匹配当前会话；结束上一位访客后不能把迟到结果显示给下一位。

| 状态 | 生命周期 |
| --- | --- |
| 照片草稿、备注、失败上传 payload | 当前进程内保留，不保证 App 被终止后恢复 |
| 上传结果不确定 | 本进程转入 Staff 待核查，暂停新登记；不得修改 request_id 内容后重试 |
| 待处理格口命令 | Application Support 下 `Found/pending-locker.json`，原子写入且带文件保护 |
| 格口 journal 内容 | 服务器地址、request_id、item_id、kind，不保存 API Key |
| App 重启发现格口 journal | 暂停新登记，首页提供原格口步骤的只读查询／续办；不自动再次开锁 |
| 服务端库存和格口状态 | SQLite 持久化；客户端会话结束不会删除库存或释放格子 |

发送格口命令前必须成功写 journal；写入失败则不发请求。操作完成后清理 journal；清理失败仍保留可恢复状态。明确的拒绝错误可结束该未接受请求，网络超时或响应不确定需保留原标识。原请求恢复继续使用相同标识，查询与访客续办只 GET。

### 未完成格口的续办

退出当前步骤、空闲返回首页或重启 App 后，首页 I found something 的说明变为 Finish the compartment step, then register another item.，操作文字变为 Continue compartment step。此时点击会进入 Your compartment，仅查询 journal 记录的原 operation。恢复页显示格口步骤，不展示前一位访客的照片或备注。

客户端校验服务器地址、操作 ID、物品 ID、操作类型和会话是否仍匹配，再根据结果处理：

| 查询结果 | 处理方式 |
| --- | --- |
| `awaiting_confirmation` | 恢复原存入／领取步骤和门状态监测，等待用户明确确认；不会再次开门 |
| `completed` | 清理过时的 journal；有可用格口且无未决上传时可继续新登记，否则回首页 |
| `actuating` | 保留原命令，只能 Check again 查询进度，不能确认完成或重新开锁 |
| `uncertain` | 保持格口待核查，提示工作人员检查；不能通过普通完成按钮解除 |
| 404、断网、身份不匹配或取消查询 | 保留 journal；可重试读取，持续无法确认时由工作人员处理 |

首页也会定期刷新格口状态。若待处理命令已在另一端完成，客户端 GET **同一个 operation 并验证其确为 `completed`** 后自动清理过期 journal，避免入口一直锁住；仅从活动列表中消失不算完成证据。这种自动清理不恢复旧照片，也不提交完成请求。

**上传未决与格口未决分开处理。** 格口步骤允许上述访客续办；照片上传结果不确定时，图片和原 `request_id` 只在当前进程保留，结束会话后仍须经 Staff 检查，不能借格口续办绕过上传核查或把同一请求换成另一张照片。

Finish 清理访客照片展示、输入、结果和导航。空闲 120 秒开始 30 秒倒计时，可 Keep Working；总计 150 秒后返回首页。上传/格口请求执行中避免中断；进入后台清理录音并按当前忙碌状态处理会话。结束访客不会把尚未确认的物理操作当作完成。

## 5. 工作人员与权限

Staff 使用设备密码、Touch ID 或 Face ID；未配置设备认证时保持锁定。退出、进入后台或工作人员入口超时后重新锁定。工作人员可以设置连接、导入照片、重试识别、检查未知上传或格口操作。正常的 `awaiting_confirmation` 格口步骤可由访客续办；`uncertain` 等无法确认的结果仍须检查实物，`resolve` 的结果必须基于实际检查。

需要相机、麦克风、本地网络权限；Photos Picker 不等于申请整个照片库读取权限。正式固定摆放时由工作人员配置系统 Guided Access。App 前台保持屏幕唤醒。

**设备认证不是 API 鉴权。** iPad 访客／格口接口仍按受信局域网站点使用；网页后台 `/api/admin/*` 使用独立的管理员密码和 HttpOnly Cookie 会话。iPad 的 Staff 解锁不等于网页后台登录，也不会自动给公共 API 增加管理员身份。

## 6. 构建与验证

在仓库根目录执行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Lost&Found.xcodeproj' -scheme 'Lost&Found' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Xcode 打开工程，选择 scheme 和实际设备，真机需有效签名团队。原生 XCTest 命令、门反馈／续办回归检查和真机验收记录见[测试文档](05-verification-roadmap.md)。[AppStoreTests.swift](../../NativeTests/AppStoreTests.swift) 覆盖读数过期、开门禁用完成、已完成 journal 清理、访客续办不重开门，以及未知／丢失／失败响应保留原命令。iOS 17 部署目标编译通过不等于在 iOS 17 真机完整运行过；模拟器使用的隔离后端也不能替代实际锁体的验收。
