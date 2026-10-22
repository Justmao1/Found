# Found · SwiftUI iPad + Raspberry Pi

> 现行技术资料入口：[项目技术文档](docs/technical/README.md)。涵盖当前四格口代码、API、硬件、部署及验证状态；旧验证条目按日期理解。

**部署在固定失物招领处的 SwiftUI 原生 iPad 终端，配套树莓派 Python 后端。** 设备由站点统一设置，供现场办理登记和查找使用，不是分发给每位用户的个人 App。原生端由原有网页客户端迁移而来，沿用 Python 服务和 SQLite 数据；App 内没有 WebView，也不保存 AI API Key。

固定终端定位已记录在 `DESIGN.md`。首页提供「捡到物品」「寻找失物」两个访客任务，并显示 01～04 四个储存隔间的状态。一件物品占用一个隔间；访客在放入或取出物品并关门后确认完成，结束后清理本次操作并回到首页。工作人员通过设备认证管理站点。iPhone 适配保留为兼容和测试能力。

![Found iPad 首页](verification/home-brand-ipad.png)

本仓库包含原生 App、Xcode 工程、Python 后端及双方测试。后端位于 [`lost-found-box/`](lost-found-box/README.md)，包含原有网页、视觉识别、自然语言搜索、语音转写、隔间分配与门锁控制、配置工具及 systemd 服务示例。接口和状态约定见 [四格储存流程](docs/locker-flow.md)。API 密钥、证书、数据库、物品照片、备份和本机运行记录不纳入版本管理。

## 打开与运行

1. 用 Xcode 打开 `Lost&Found.xcodeproj`，选择 `Lost&Found` scheme。
2. 选择 iPhone / iPad 模拟器，点击 Run。最低 iOS 17，无第三方包依赖。
3. 在 App 的 **Staff → Unlock Staff Tools → Connection & device setup → Campus server** 设置服务器地址，点击 **Save & check connection**。工作人员入口使用设备密码 / Touch ID / Face ID，未设置设备密码时保持锁定。

真机默认使用 `https://work123.local:8443`。设备和树莓派须在同一网络，并允许 App 的 Local Network 权限。App 与后端应一同更新；部署仓库内完整 `lost-found-box/` 源码，包括 `iot_admin.py`、`vibration.py`、`door_feedback.py` 和 `static/`，保留站点已有配置、证书和数据库。首次使用项目自签 CA 时，先安装公开 CA 证书，再在 iOS「设置 → 通用 → 关于本机 → 证书信任设置」开启完全信任。不要将证书私钥放入 App；客户端保留系统证书与域名校验。

模拟器默认使用 `http://127.0.0.1:8080`。在 Mac 上从本仓库根目录启动后端（Python 3.10+；关闭硬件时仅需标准库）：

```sh
cd lost-found-box
python3 server.py
```

默认关闭门锁、门反馈和震动监测。要在 Mac 上检查隔间流程，可使用独立测试数据目录启动明确标注的模拟模式，并显式关闭两个独立的传感器开关；该模式只允许监听 localhost，不连接实物锁：

```sh
LOST_FOUND_DOOR_FEEDBACK_ENABLED=0 LOST_FOUND_VIBRATION_ENABLED=0 \
  python3 server.py --host 127.0.0.1 --port 8080 \
  --data-dir /tmp/found-locker-demo --locker-mode simulated
```

模拟模式只替代 GPIO，照片识别仍需要有效的 AI 配置。树莓派实物模式需要系统 `lgpio` 和显式门锁配置，详见 [后端部署说明](lost-found-box/README.md)。

模拟器的 localhost 指向 Mac；真机 localhost 指向手机自身。局域网部署使用 HTTPS，HTTP 只允许本机开发地址。真机运行还需 Xcode 中有效的签名团队。

若命令行提示当前目录是 CommandLineTools，可按命令临时指定 Xcode，无需更改全局设置：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Lost&Found.xcodeproj' -scheme 'Lost&Found' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## 原生功能

| 页面 | 功能 |
| --- | --- |
| Home | 两个大图标任务入口与四格状态；无空闲隔间或储存不可用时暂停新存入；本机存在未完成请求时可继续原隔间步骤 |
| Report | 拍照 → 确认照片 → 保存并识别 → 显示标签与分配的格号 → 解锁 → 确认已放入并关门 → 入柜回执 |
| Find | 最长 30 秒语音转成可编辑描述，键盘辅助；搜索候选 → 确认是自己的物品 → 解锁 → 确认已取出并关门 |
| Items | 访客浏览可领取的已入柜物品、原图和标签；工作人员可查看历史记录 |
| Staff | 设备认证后管理连接、相册选图、识别重试、待核实上传和中断的隔间操作 |

iPad 首页以两个大任务卡片承接访客操作，搜索、详情和设置按内容分成左右两栏；竖屏、窄窗口和辅助功能大字体自动回到单栏。Report 使用拍照入口，随后打开系统确认弹层；iPad 居中展示，iPhone 使用大尺寸 sheet。操作和状态配有 SF Symbols 图标。横竖屏切换保留当前任务和未提交的输入。

视觉与动效按 Apple 当前 Materials、Motion 和 Accessibility 指南完善：首页使用有层次的 SF Symbols 任务图案与原生卡片；玻璃材质用于操作控件，内容保持清晰的不透明底色。iOS 26 使用 Liquid Glass 按钮，旧系统采用原生材质回退。页面轻量入场、按钮按压、照片详情缩放和成功回执动效均尊重“减弱动态效果”；同时适配深色模式、“降低透明度”和增强对比度。

Report 的照片在确认、上传、识别和入柜阶段始终保留，备注最多 200 字。照片保存后展示真实识别标签；识别中自动更新，失败可单独 Retry tagging，不会再次上传照片或新增物品。只有当前访客的识别成功后，App 才发起一次隔间分配与开门请求。界面突出显示 01～04 格号；访客放好物品、关门并点击确认后，系统才将物品标记为已入柜。照片保存成功本身不会显示入柜完成。上传或隔间请求进行时禁用重复提交和结束。

领取时，访客先比较候选照片与细节，再点击 **This is my item** 并确认开门。取出物品、关门并确认后，系统在同一事务中将物品标记为 `collected`，把隔间恢复为 `free`。领取过程中返回搜索或浏览页，仍可从当前操作卡片继续确认。门锁启用时，访客搜索和浏览只提供已入柜且所在隔间确实为占用状态的物品；待存入、正在领取、待检查及已领取的物品不进入候选。

## 四格门锁与完成确认

| 隔间 | 开锁 BCM GPIO（物理针） | 门反馈 BCM GPIO（物理针） |
| --- | --- | --- |
| 01 | 17（11） | 12（32） |
| 02 | 26（37） | 18（12） |
| 03 | 13（33） | 未接，人工确认 |
| 04 | 5（29） | 未接，人工确认 |

四路均使用 S8050 NPN 三极管驱动 LOW 触发继电器。GPIO 低电平为不动作，高电平脉冲持续 0.5 秒后恢复低电平；三极管将这一脉冲转换成继电器 IN 的低电平。GPIO5 用作第 04 路输出，不接门锁反馈触点。

01／02 的无源锁扣反馈分别接 GPIO12／18 与 GND，内部上拉，LOW 表示已扣住。服务独立消抖两路输入，iPad 存取页面每秒读取当前操作，显示 **Door not closed** 或 **Door closed**；只有新鲜的已关闭读数才允许完成，后端也独立检查。关门后仍需访客确认已放入／取走物品，关门本身不会改变库存。03／04 保留人工确认。反馈只反映锁扣，不能检测物品是否在格内；开锁输出电平也不等于门状态。配置与异常状态见 [门反馈说明](docs/door-feedback.md)。

后端先原子保留空闲隔间、记录操作，再发送单次脉冲。同一请求 ID 的重复请求只返回已有结果，不重复开门。退出访客会话、网络中断或服务器重启都不会自动释放隔间，也不会自动补发开门脉冲。未完成操作需继续确认或由工作人员实际检查后处置。硬件配置、运行方式和恢复接口见 [后端 README](lost-found-box/README.md)；完整状态与 HTTP 契约见 [四格储存流程](docs/locker-flow.md)。

升级会保留原有照片记录；没有储存状态的历史物品保持 `recorded`，不会自动认定已入柜、分配隔间或开门。工作人员仍可查看这些记录。已有物品是否实际存放在柜内，需要单独核实。

## 访客会话与恢复

物品主类别和第一个识别标签旁显示匹配的 SF Symbols 图标，覆盖水瓶、钥匙、包、数码设备、衣物和文具等常见失物。Report、物品列表、搜索结果和详情共用本地类别表 `Lost&Found/Core/ItemCategory.swift`；支持常见同义词、复数和格式变化。颜色和特征标签保留文字，未知类别使用通用物品图标。沿用服务端“第一个标签为主类别”的约定，不新增识别请求，也无需下载图标。原始标签文字保持不变。

访客不能进入系统相册或修改服务器。Finish 清理搜索输入、搜索结果、未提交照片、备注、回执和导航；保存的物品和站点配置不受影响。空闲 120 秒显示 30 秒倒计时，可选择 Keep Working；到期自动返回首页。进入后台时，在上传或隔间请求结束后复位。旧会话的异步搜索、选图和开门操作不能进入新会话。结束尚未确认的储存或领取操作会保留请求及隔间归属；首页仍可点击 **I found something → Continue compartment step** 继续待确认步骤，恢复页不展示上一位访客的照片或备注。

隔间请求在发送前原子写入 iPad Application Support 的 `Found/pending-locker.json`；本地写入失败时不发送开门请求。重启后沿用同一请求 ID。首页刷新会查询旧请求，已完成则清除过期日志、恢复登记；未完成时由访客明确点击继续，仅 GET 查询原操作。只有 `awaiting_confirmation` 恢复正常关门与物品确认；缺失、离线或不确定的结果保留待处理状态，不补发开锁脉冲。工作人员的 **Check pending request** 仅读取状态，**Retry the same request** 沿用原 ID。现场检查后可处置为「已存放／空格」或「已领取／仍存放」，处置不再次开锁。树莓派 SQLite 同时持久保存隔间与操作状态。

照片上传结果不确定时，结束操作会把原上传请求留给工作人员核查和重试，下一位访客看不到其照片或备注；此时暂停新登记，查找仍可使用。**照片草稿与待重试上传仍只保存在当前进程中**，不同于已持久化的隔间请求日志。退出进程不保证保留未完成照片草稿。

工作人员入口关闭、App 进入后台或入口空闲 120 秒后重新锁定。App 在前台保持屏幕唤醒；正式摆放设备前，工作人员需在 iPad「设置 → 辅助功能 → 引导式访问」完成配置并启动引导式访问。设备密码与已录入生物识别仅供工作人员使用。App 内认证限制界面入口，不替代后端鉴权。

工作人员选择照片无需请求整个相册访问权限。照片先归正方向、缩至最长边 1600 像素，再转为 JPEG；透明区域填白。失败上传保留当前会话中的图片、备注和原始请求 ID，重试不会新增重复记录。提交失败后备注保持锁定，避免同一请求 ID 携带不同内容。退出进程不保证保留尚未完成的草稿。

识别中会在前台轮询；进入后台停止轮询，返回前台刷新。切换服务器清空旧数据和详情导航，过期响应不能覆盖新服务器数据。搜索错误保留输入，空结果与网络错误分别呈现。

## IoT 管理网页与震动报警

英文管理台入口为 **https://work123.local:8443/admin/**，使用独立站点管理员密码登录。页面显示 CPU、内存、磁盘、温度、网络、服务状态、物品信息、四格占用与门反馈，每 3 秒刷新。点击格子上的 **Open** 即可发送一次开锁命令，无需填写原因或再次确认；手动开门不修改物品库存。

震动模块 DO 接 BCM GPIO21（物理 40），3.3V 供电、共地。2 秒内累计 5 次有效触发会生成持续报警，后台弹出明显的 **Shaking detected** 警告。**Dismiss** 只关闭弹窗，**Clear alert** 才确认清除该条报警；监测与历史保存在树莓派端。说明见 [管理台](docs/iot-admin.md)、[震动监测](docs/vibration-monitoring.md)。

当前演示使用 01／02 两路门反馈，用户已确认锁扣变化能反映到界面；03／04 仍提供开锁输出与人工完成确认。部署及自动测试证据见 [验证矩阵](docs/technical/05-verification-roadmap.md)，不将两路反馈验证等同于四把锁完整现场验收。

## 语音输入

语音只在访客点击麦克风后开始；再次点击停止并识别。取消、离开查找页、进入后台或会话结束都会停止并清理录音。拒绝麦克风权限或识别失败时可以继续键入，已有描述保留。录音以临时 WAV 文件采集（16 kHz、单声道、16-bit PCM），上传前删除临时文件，后端不保存音频或转写记录。识别文字最多 500 Unicode 码点，须确认后才会搜索。

后端通过 `/api/transcribe` 调用百炼 `qwen3-asr-flash`，复用视觉服务的 API Key 与北京地域 host；密钥仅在服务器端。访客界面提示音频会发送至 Alibaba Cloud。若同一 Key 的模型权限不包含 ASR，需要工作人员在百炼配置权限。接口参考：[Qwen ASR 官方文档](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)。

## 代码组织

- `Lost&Found/Core/`：物品与隔间数据契约、URL 校验、URLSession API 客户端。由 App 与 Swift Package 测试共用源码。
- `Lost&Found/AppStore.swift`：主线程状态、上传重试、搜索、识别、隔间操作及本地请求日志。
- `Lost&Found/UI/`：SwiftUI 页面、组件、相机桥接和图片处理。
- `DESIGN.md`：原生迁移的界面约定，延续网页的英文内容与绿色品牌。
- `Tests/`：Foundation 接口契约测试。
- `NativeTests/`：iOS 图片处理和状态竞争回归测试。
- `lost-found-box/`：树莓派后端、四格状态与 GPIO 驱动、门反馈、震动监测、管理台和兼容照片网页、部署示例、Python/网页测试。部署及百炼 Key 配置见该目录的 README。
- `docs/locker-flow.md`：四格分配、存入、领取、恢复和接口约定。

## 验证

```sh
# 核心模型、网络请求及地址校验
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# 真实 Python 后端联调：临时数据库、无 AI 密钥、自动清理
python3 Tools/verify_api_integration.py

# 四格存取闭环：模拟 GPIO、容量、领取与幂等
python3 Tools/verify_locker_integration.py

# 后端回归测试，在本仓库的 lost-found-box 目录执行
cd lost-found-box
python3 -m unittest discover -s tests -v
node --test tests/test_camera.js  # 可选；服务运行不需要 Node
cd ..

# 原生 XCTest，按本机可用模拟器调整 destination
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Lost&Found.xcodeproj' -scheme 'Lost&Found' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

验证记录见 [当前验证矩阵](docs/technical/05-verification-roadmap.md)和 [原生历史记录](verification/README.md)。自动化验证使用隔离数据库与模拟驱动，不触发实物锁。2026-10-22 最近记录为 196 项 Python、44 项 Swift Core、62 项原生测试，以及 13 项四格 HTTP 工作流检查通过；它们来自各次对应功能验证，完整范围和设备实测另列于验证矩阵。后端面向可信局域网；管理台 `/api/admin/` 有密码会话保护，兼容的访客 API 未做统一用户鉴权。App 的工作人员认证只保护设备界面入口。

## Apple 参考

- [Materials / Liquid Glass](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [自定义 SwiftUI 控件的 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [SwiftUI Observation](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)
- [系统 Photos Picker](https://developer.apple.com/videos/play/wwdc2023/10107/)
- [原生 Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
- [进度反馈](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- [本地网络隐私](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
- [手动安装 CA 的信任设置](https://support.apple.com/en-us/102390)
- [引导式访问](https://support.apple.com/en-us/111795)
- [Local Authentication](https://developer.apple.com/documentation/localauthentication/logging-a-user-into-your-app-with-face-id-or-touch-id)
