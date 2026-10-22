# Found · 树莓派后端与 IoT 管理台

> 当前系统文档见[技术文档总览](../docs/technical/README.md)，包含原生 App、四格口、API 和运维。以下部署记录保留历史日期，不能作为实时设备状态。

## 在 Found 仓库中运行

后端与 SwiftUI App 现在共同维护于 [Justmao1/Found](https://github.com/Justmao1/Found)。从仓库根目录进入 `lost-found-box/` 即可运行本页命令，无需额外复制旁边的项目目录。

```bash
git clone git@github.com:Justmao1/Found.git
cd Found/lost-found-box
python3 server.py
```

首次克隆不包含 `config/`、`certs/`、`data/`、`backups/` 和 `api.md`。无 AI 配置时仍可本地登记照片；需要 AI 时运行 `python3 tools/configure_ai.py`，密钥在终端隐藏输入并写入本机忽略的配置文件。HTTPS 证书按下文生成。

`deploy/` 的用户级 systemd 示例沿用项目树莓派的 `%h/lost-found-box` 部署目录。新设备若直接从 Git 克隆目录运行，先将示例里的 `WorkingDirectory` 和 `ExecStart` 路径改为实际目录，再安装至 `~/.config/systemd/user/`。已有设备更新源码时保留原来的配置、证书和数据库。

2026-10-22 入库说明：源码取自本机维护的后端目录。下方部署条目保留当时的验证结果；当前四格储存流程见下一节。独立门锁脚本保留用于诊断，自动测试使用假驱动，不驱动真实 GPIO。

## 功能

当前实现：拍照或选择照片 → 预览／重拍 → 可选备注 → 上传登记 → 后台自动识别 → 查看最多5个类别、颜色、外形标签。照片先保存，识别失败可单独重试。

**百炼图片识别与短录音转文字供原生 iPad 访客自助应用使用；四格储存流程通过下述显式硬件模式启用。** 页面显示“照片已登记”，不表示物品已入柜。树莓派运行服务与 SQLite，旧网页仍是照片登记工具，不提供柜门流程。英文 IoT 管理台位于 `/admin/`，以独立站点密码保护后台操作。访客 API 仍无个人账户鉴权，任何能访问业务地址的人都可以查看及提交登记；部署面向可信局域网课堂演示。

## 四格储存与领取

用户确认的开锁 BCM 引脚为 `01=17、02=26、03=13、04=5`，对应物理针脚 `11、37、33、29`。四路均经 S8050 三极管接 LOW 触发继电器；GPIO HIGH 开启，LOW 关闭，每次仅输出一个 0.5 秒 HIGH 脉冲。GPIO5 用于第四把锁，不兼作反馈输入。

01 的锁扣反馈接 **GPIO12／物理 32**，02 接 **GPIO18／物理 12**；各自干接点另一根线接 GND，内部上拉，LOW 表示扣住。服务每 50 ms 独立采样、稳定 250 ms 后确认状态，超过 1 秒无新采样则不可用。iPad 存取页显示 **Door not closed**／**Door closed**，后台也显示门状态；01／02 只有当前反馈 closed 时才能普通确认完成，03／04 保留人工确认。没有物品在位传感器，**关门不会自动入库或领取，访客仍须明确确认物品已放入／取走**。详见[门反馈](../docs/door-feedback.md)。

照片保存和识别不直接触发门锁。iPad 在识别完成后发起独立存物操作，服务器在 SQLite 事务中分配 `01`～`04` 的首个已结束冷却的空格，先持久保存操作再输出脉冲。确认已放入后才进入可领取库存。领取时重新核对物品及格子归属，发出单次脉冲；确认已取出后，物品标为 `collected`，格子回到 `free`。一次只能存一件物品，每格同时只能存在一个未完成操作。

默认 `disabled` 模式关闭开锁驱动，新的柜门操作返回 503；门反馈／震动由各自独立开关控制，均默认关闭，全部关闭时不加载 lgpio。停用开锁后，曾由格子管理的物品仍须处于 `stored` 且对应格子为 `occupied` 才可搜索，已领取、待确认或待检查物品不会重新出现；从未进入格子流程的旧照片仍保留登记／搜索。新增物品字段 `compartment_id` 可为 null，原有记录保持 `recorded`，不自动分配格子。`GET /api/items` 保留全部历史记录；访客浏览使用 `GET /api/items?available=1`，始终只返回 `stored` 且实际格子状态为 `occupied` 的记录。柜门启用时，语义搜索也只使用这些可领取记录。状态查询不发开锁脉冲，会附上当前门反馈；仅在独占硬件锁且没有执行中的脉冲时，可以把遗留 `actuating` 操作标为待检查。

本机联调使用独立数据目录和显式模拟模式：

```bash
LOST_FOUND_DOOR_FEEDBACK_ENABLED=0 LOST_FOUND_VIBRATION_ENABLED=0 \
  python3 server.py --host 127.0.0.1 --port 8081 --data-dir /tmp/found-locker-demo --locker-mode simulated
```

上面的模拟配置不加载 GPIO，只允许监听 localhost；不要指向正式数据库。树莓派需已有系统 lgpio 软件包，并显式配置 `LOST_FOUND_LOCKER_MODE=gpio` 及 `LOST_FOUND_LOCKER_GPIO_MAP=01=17,02=26,03=13,04=5`。提供的 systemd 服务读取 `config/lockers.env`，内容参考 `deploy/lockers.env.example`。门反馈通过 `LOST_FOUND_DOOR_FEEDBACK_ENABLED=1` 同时启用 01／02；震动通过 `LOST_FOUND_VIBRATION_ENABLED=1` 启用 GPIO21。修改后重启服务；监测开启后持续占用对应输入，开锁输出只在明确开门请求中由驱动核对和控制。驱动先检查 Pi 4B 芯片和四路 GPIO 可用性，硬件不可用时不分配新格子。

接口均沿用 JSON 和 `X-Requested-With: lost-found-box` 请求头：

| 接口 | 请求与行为 |
| --- | --- |
| `GET /api/lockers` | 返回 enabled、driver、四格状态和未完成 operations；格口／操作包含 door 反馈 |
| `POST /api/locker-operations` | `{request_id,item_id,kind}`，kind 为 deposit 或 retrieve；首次 201，重复 200 |
| `GET /api/locker-operations/<uuid>` | 返回 `{operation,item}`，不再次开门 |
| `POST /api/locker-operations/<uuid>/complete` | `{}`；确认已放入／已取出，01／02 须反馈 closed；已完成请求可安全重复 |
| `POST /api/locker-operations/<uuid>/resolve` | `{outcome}`；工作人员实际检查后的处置，绝不触发 GPIO |

operation.id 等于客户端 request_id，均须使用规范 UUID。操作状态为 `actuating`、`awaiting_confirmation`、`completed` 或 `uncertain`；同一 ID 内容不同返回 409，不同 ID 也不能绕过同物品／同格子的未完成操作。四格满返回 409，硬件不可用返回 503。存物分配会跳过冷却中的空格，仅在所有空格仍在冷却时返回 429；取物只能使用原格子，该锁 30 秒冷却未结束时返回 429。冷却时间持久保存在数据库，并与独立诊断脚本的文件锁／时间戳协调。

请求丢失、App 退出或服务器重启不会自动重复脉冲，也不会自动释放格子。iPad 保存原请求编号：入口 **I found something** 可显示 **Continue compartment step**，查询原操作并恢复 `awaiting_confirmation` 步骤，不重新开锁；服务端已完成时清理本机旧记录。未确认的门状态变化也不会自动修改库存。

启动时未完成的 `actuating` 改为 `uncertain`，格子保持 `recovery`；开门期间的异常或脉冲后的状态保存失败也如此。如果数据库暂时连待检查状态也无法写入，后续查询／重试／确认会在硬件空闲且独占锁时恢复待检查状态，不需要重启，不会重放脉冲。`uncertain` 必须展示待工作人员检查，普通 `complete` 不能确认。工作人员检查后，存物操作可 resolve 为 `stored`（确已放入）或 `empty`（格子确为空）；取物操作可为 `collected`（确已取出）或 `stored`（物品仍在）。已完成操作不能改成另一种结果。管理台使用有会话保护的 `/api/admin/locker-operations/<uuid>/resolve`；兼容访客 `/api/locker-operations/<uuid>/resolve` 仍无该鉴权，整个服务仍依赖可信局域网。

普通完成请求遇门 open／unknown 返回 409，unavailable 返回 503，物品和格口保留原状态；已完成请求重放不受之后门状态变化影响。人工 resolve 在现场核实后可处理传感器异常，不发开锁脉冲。

SQLite 状态与物理 GPIO 无法构成原子事务；崩溃可能留下“可能已开门”的操作，因此一律保留格子等待检查。软件脉冲时长与 GPIO 读回不等于硬件安全截止或门确已打开。真实门锁、供电及手工确认流程仍须现场验收，模拟测试不会执行开锁。

## IoT 管理台与震动报警

访问 **https://work123.local:8443/admin/**。英文页面展示设备 CPU／内存／磁盘／温度／运行时间和网络指标、服务状态、物品照片与标签、四格分配、独立门反馈及最近操作。概览前台每 3 秒刷新，最近 120 个设备采样保存在内存；不支持或过期的数据不会当作正常读数。

首次设置或修改管理密码，在树莓派交互式终端运行：

```sh
cd ~/lost-found-box
python3 tools/configure_admin.py
systemctl --user restart lost-found-box.service
```

密码为 12–256 字符，写入 `config/admin-password.txt`（权限 600），可用 `LOST_FOUND_ADMIN_PASSWORD_FILE` 指定路径。服务启动读取，重启使旧会话失效。浏览器使用有效期 8 小时的 HttpOnly／SameSite=Strict 会话 Cookie，HTTPS 附加 Secure。iPad Staff 设备认证与管理网页密码分开。

每格的 **Open** 一次点击开门，无填写原因或重复确认；成功提示 **Opening command sent**，服务自动恢复原软件状态，不改变库存，也不代替访客完成存取。请求 UUID 保留以应对丢失响应，重复相同请求不会再次发脉冲；异常人工操作可用 **Finish** 结束，待处理访客记录仍独立处理。

震动模块 VCC 接 3.3V、GND 接地、DO 接 **GPIO21／物理 40**，HIGH 触发。后台连续监听，两次计数至少间隔 100 ms，2 秒内 5 次形成报警；开锁前抑制计数 2 秒过滤锁体动作。报警在下一次概览刷新后显示明显的 **Shaking detected** 弹窗，含红色图标、遮罩和检测时间。**Dismiss**／Escape 只关闭弹窗，**View alert** 可重开，**Clear alert** 清除指定报警；同一报警不每次刷新都重复打断。报警记录和未清除状态跨服务重启保留，不自动开门或修改库存。

详细说明：[管理台](../docs/iot-admin.md)、[接口契约](../docs/iot-admin-contract.md)、[门反馈](../docs/door-feedback.md)、[震动监测](../docs/vibration-monitoring.md)、[部署与维护](../docs/technical/04-deployment-operations.md)。

2026-10-22 反馈验收：用户已分别确认 01（GPIO12）和 02（GPIO18）的锁扣变化能在 iPad／后台正确显示。03／04 当时未接反馈，继续人工确认。该记录不替代后续接线变更后的现场验收。

## 已部署到项目树莓派（2026-10-13）

- 主机：`wlb123@work123.local`，该次部署 IP 为 `192.168.5.3`；10 月 22 日后续记录为 `192.168.1.141`，运行时应重新确认。
- iPad 首次设置：<http://192.168.5.3:8088>，仅提供公开 CA 证书和安装说明。
- 照片登记：<https://192.168.5.3:8443> 或 <https://work123.local:8443>。
- 服务目录：`/home/wlb123/lost-found-box`。用户级 systemd 服务 `lost-found-box.service` 与 `lost-found-setup.service` 已启用，用户 linger 已开启，SSH 退出后保持运行。
- 已验证树莓派上 10 项后端测试、可信 HTTPS、实际网络上传／读回／去重、服务重启后持久化；未重启整机，用户已在实际 iPad 拍照并保存，服务端已核对照片读回。
- 当时签发的证书有效期至 2027-01-11；当前期限应以证书文件核对。IP 更换且通过新 IP 访问时，需要重新签发覆盖该 IP 的服务器证书。

在树莓派维护服务：

```bash
systemctl --user status lost-found-box.service lost-found-setup.service
systemctl --user restart lost-found-box.service
# 不再需要证书安装页时，可以单独关闭：
systemctl --user disable --now lost-found-setup.service
```

下文“手动启动”用于复现或其他设备；已部署的树莓派不必重复执行，否则会与后台服务争用端口。

## 在当前电脑运行

HTTP、数据库和模拟模式使用 Python 标准库，无需 pip／npm 安装；当前代码要求 Python 3.10+。真实 GPIO 开锁及传感器监测还需要系统 `lgpio`。

```bash
cd lost-found-box
python3 server.py
```

浏览器打开 http://localhost:8080 。本机 localhost 可以申请摄像头权限；没有摄像头也可“选择照片”。默认只监听本机。

## 在树莓派上运行，供 iPad 访问

### 准备文件和 HTTPS 证书

在当前电脑的 `lost-found-box` 目录执行：

```bash
python3 tools/make_tls.py --hostname work123.local --ip 192.168.5.3
```

`192.168.5.3` 是此前网络检查得到的地址，运行前应按树莓派当时的 `hostname -I` 核对。可省略 `--ip` 并只通过证书里的主机名访问。证书工具依赖系统 OpenSSL，会生成独立的项目 CA，不改动电脑系统信任；服务器证书有效期 90 天。地址改变时使用新 IP 加 `--renew` 重新签发，原 CA 保留。

SSH 可用后，在当前电脑执行：

```bash
ssh wlb123@work123.local 'mkdir -p ~/lost-found-box/certs'
scp server.py vision.py search.py speech.py lockers.py iot_admin.py door_feedback.py vibration.py \
  wlb123@work123.local:~/lost-found-box/
scp -r static tools wlb123@work123.local:~/lost-found-box/
scp certs/server.crt certs/server.key wlb123@work123.local:~/lost-found-box/certs/
ssh wlb123@work123.local 'chmod 600 ~/lost-found-box/certs/server.key'
```

只传服务端证书和密钥。不要把 CA 私钥 `ca.key` 上传、分享或放进代码仓库。

在树莓派终端启动：

```bash
cd ~/lost-found-box
python3 server.py --host 0.0.0.0 --port 8443 --cert certs/server.crt --key certs/server.key
```

手动启动会持续运行在当前终端，Ctrl+C 停止。项目树莓派已使用前述后台服务，不需要此步骤。启动失败时检查 Python、端口占用和证书路径。

### 在项目 iPad 信任证书

1. 将 `certs/ca.crt` 通过 AirDrop／文件传输送到项目 iPad，只传这个公开证书。
2. 在设置里安装对应证书描述文件，然后到“通用 → 关于本机 → 证书信任设置”开启此项目 CA 的完全信任。受管理设备可能不允许安装，菜单随系统版本可能不同。
3. iPad 与树莓派连接可互通的 Wi-Fi，在 Safari 打开 `https://work123.local:8443`，或打开证书覆盖的 `https://192.168.5.3:8443`。
4. 网站不应显示证书警告。点击“打开相机”，授权后使用后摄拍照；后摄不可用时浏览器可能使用其他摄像头。
5. 页面持续在前台使用；切到后台时会停止相机，返回后点击打开相机恢复。

普通 `http://192.168…` 不是远端相机的部署方式，服务器也拒绝非本机的明文绑定。仅在浏览器点“忽略证书警告”不等于完成可信 HTTPS 配置。

使用结束后可以从项目 iPad 移除该 CA 的信任与描述文件。

## 数据和使用限制

- 数据默认保存在 `data/items.sqlite3`，相对于 server.py 所在目录，不随工作目录改变。图片和记录写入同一个 SQLite 事务，重启后保留。
- 可用 `--data-dir /绝对路径` 指定其他目录。备份时先正常停止服务，再复制整个 data 目录（包括可能存在的 WAL 文件）。
- 列表显示最新 100 条及总数，照片可点击查看原图。每条记录包含服务器 UTC 时间，网页按设备时区显示。
- 浏览器将照片缩到最长 1600 像素并转成 JPEG；原始文件超过 25MB 提示换图。后端接受最多 5MiB JPEG／PNG，请求体最多 8MiB，备注最多 200 字符。
- 后端校验图片容器结构和尺寸，未执行完整像素解码；不作为面向不可信互联网用户的图片处理服务。
- 上传失败后保留当前照片和请求 ID，直接再次保存不会重复登记。首次提交后备注锁定以保证重试内容一致；要改内容需重新选择照片。页面刷新会清除尚未保存的草稿，应先查看列表确认上次是否成功。
- 同一张图作为新的一次登记可以再次保存；幂等针对同一次请求重试，不自动把相同外观的不同物品合并。
- 暂无访客账户、物品删除或自动物品清理；管理台使用站点密码，取物状态由四格流程管理。存储空间不足会返回保存失败，不应显示成功。震动报警单独保留最近 100 条。

## 验证

```bash
python3 -m unittest discover -s tests -v
node --check static/app.js  # 开发电脑可选；树莓派运行不需要 Node
node --check static/admin.js
node --test tests/test_camera.js  # 开发电脑上的相机生命周期回归测试
```

手工验收：

1. 选择一张真实照片，备注后保存；列表出现照片，刷新页面仍在。
2. 打开照片原图确认上传正确，重启服务后记录仍在。
3. 断开服务后保存，页面显示失败并保留照片；恢复服务后重试只产生一条记录。
4. 拒绝摄像头权限时有提示，仍可选择已有照片。
5. 实际 iPad 检查证书信任、前后摄、旋转方向、暂停／恢复相机及连续拍照登记。

自动测试不能替代实际 iPad 和树莓派验证；验收结果见 `VERIFICATION.md`。

## 文件

`server.py` 为标准库服务器；`vision.py`／`search.py`／`speech.py` 调用 AI；`lockers.py` 管理四格状态；`iot_admin.py` 提供管理会话和遥测；`door_feedback.py`／`vibration.py` 读取传感器。`static/` 包含旧照片页和英文管理台，无构建步骤；`tools/` 包含证书、管理员／AI 配置和单次开锁诊断；`tests/` 覆盖 HTTP、数据库及假 GPIO。当前实现不使用 FastAPI。

参考：[WebKit 摄像头访问和 HTTPS](https://webkit.org/blog/7763/a-closer-look-into-webrtc/)、[Apple 手动安装证书的信任设置](https://support.apple.com/en-us/102390)。

## 百炼图片识别

在电脑终端运行下列命令，API Key 使用隐藏输入，不要粘贴到聊天或命令参数中：

```bash
ssh -t wlb123@work123.local 'python3 ~/lost-found-box/tools/configure_ai.py'
```

按提示输入 Key；默认视觉模型 `qwen3-vl-plus`（须在北京地域账户可用）。业务空间 ID 可选：提供后使用空间专属域名，留空使用官方仍支持的 `https://dashscope.aliyuncs.com/compatible-mode/v1`。两者都调用 `/chat/completions`。模型名可在设置时更改。

配置写入树莓派 `config/ai.json`，权限 600，已加入忽略规则。服务每次动态读取，刷新 iPad 网页即可启用。`GET /api/ai/status` 的 configured 只表示本地配置存在且格式有效，不代表 Key、额度或模型权限已经验证。也支持 `LOST_FOUND_AI_CONFIG` 指定配置路径或 `DASHSCOPE_API_KEY` 环境变量。项目打包时必须排除 config、certs、data 和存有凭据的 api.md。

保存记录后，服务器自动将该照片的 Base64 发送至百炼。备注不发送。仅提取最多5个短标签，每个不超过24个字符，优先为类别、颜色、形状或显著外观。身份证和银行卡仅分类，不读取姓名、号码、地址等个人信息；不提取标签文字或背景物品。页面显示标签，可用于后续搜索，但不能据此认定所有权或自动开锁。

识别成功后保存到 SQLite 的独立 recognitions 表，已有照片结构不变。成功结果复用，同物品并发请求共享调用，自动识别使用有界后台队列；失败不因轮询或服务重启自动重试，不删除照片。显式“重试识别”可以再次调用。主动重试失败请求可能产生新的 API 费用。云请求设置30秒 socket超时，浏览器45秒等待；不是整体耗时的硬实时保证。

接口：`POST /api/items/<uuid>/recognize`，JSON `{}`，请求头 `X-Requested-With: lost-found-box`；返回 `{item: ...}`，物品含 `recognition` 字段（未识别为 null，成功为 `{tags, model, version: 3}`）和 `recognition_status`（pending/processing/failed/disabled/complete）。列表同样返回识别字段。API Key 不返回浏览器，云端原始错误不进入页面。

依据：[图像与视频理解](https://help.aliyun.com/zh/model-studio/vision)、[Chat API 参数](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions)。当前仅面向可信局域网演示：访问页面的人都可发起识别，尚无用户级鉴权或累计费用配额。

2026-10-13 实测：北京地域 `qwen3-vl-plus` 成功识别已有 iPad 照片，返回“鲜牛奶瓶”及结构化特征。Key 支持带点分段的完整凭据，不应按固定前缀长度或不完整正则截取。

2026-10-14 改为后台自动识别及简短标签。旧版长描述不再展示，已配置的服务启动后会将旧记录重新识别为标签。失败时保留照片，页面提供“重试识别”。页面在待识别期间轮询结果，刷新页面不会重复发起识别。

界面已切换为英文，包括按钮、提示、错误信息、辅助阅读标签和日期格式。新识别仅输出1–5个简短英文标签。识别缓存版本为3，原中文标签会自动更新为英文；用户输入的备注原样保留。

## 自然语言查找

页面顶部选择 **Find an item**，输入自然语言描述（中文、英文均可），点击 **Find matches**。服务器把描述和库中已有标签、备注交给百炼模型比较语义，返回最多5条真实记录及简短英文匹配理由。照片由本地服务展示，搜索时不重复向云端上传照片。

`POST /api/search` 接收 `{"query":"I lost a white bottle with a green label"}`，同样要求 JSON 和 `X-Requested-With: lost-found-box`。描述最长500字符，请求体最大16KiB。结果为 `{matches:[{item,reason}],searched_count,pending_count}`。未生成有效标签的记录暂不进入搜索，会在界面提示数量；无候选返回空列表，API错误显示失败且保留描述。

当前课堂版一次比较全部有效标签记录，上限200条，超过会明确拒绝而不会只搜部分记录。搜索并发上限1，无自动云端重试。模型返回的候选ID必须属于本次真实库存，重复或不存在的ID会被拒绝。自然语言/备注作为数据处理；它们不会修改数据库或触发开锁。

默认照片演示模式可搜索所有完成标签的登记；启用四格流程后，只搜索确认存入且仍占用格子的物品。AI匹配不验证所有权，访客需要查看候选并明确选择自己的物品。搜索依赖已有标签和备注：如果标签漏掉某个细节，仅描述这个细节可能无法找到。原生 iPad 应用可通过下述接口将录音转为描述，再调用搜索；现有网页仍使用文字输入。

## 短录音转文字

`POST /api/transcribe` 接收 JSON `{"audio":"标准 Base64 编码的 WAV 文件","mime_type":"audio/wav"}`，要求 `Content-Type: application/json` 和 `X-Requested-With: lost-found-box`，沿用同源及请求长度校验。成功只返回 `{"text":"a blue water bottle"}`。接口只转写录音，不自动搜索、登记物品或改变数据库。

录音必须是单声道、16 kHz、16-bit PCM WAV，时长0.3–30.5秒，完整文件最多1,000,000字节，JSON请求体最多1,400,000字节。服务校验实际 RIFF 结构、完整帧数据和严格标准 Base64，拒绝截断文件、格式伪装和不一致的长度。结果去除首尾空白后须为1–500个 Unicode 码点；未识别到语音或描述过长返回422，提示重新录音或简短描述。

`speech.py` 复用图片识别的服务端 API Key 和北京地域主机，将兼容接口路径替换为 `/api/v1/services/aigc/multimodal-generation/generation`，固定调用 `qwen3-asr-flash`，不使用视觉模型名。已有 Key 还需具备该 ASR 模型的调用权限和额度；`GET /api/ai/status` 不验证 ASR 权限。配置和 Key 都不会发送到 iPad，不能把 Key 写入应用。

收到录音后会把音频发送到阿里百炼转写。此服务不把录音或转写结果写入文件、数据库或日志；后续用户主动提交搜索时，描述会像文字搜索一样发送至百炼。云服务的数据处理以其服务约定为准。应用应在访客结束操作后清除尚未提交的描述和录音。

转写有独立的单请求并发限制，忙时返回503，不占用图片识别或语义搜索队列；配置缺失也返回503。云请求设置30秒 socket 超时、最多64 KiB响应、禁止重定向及环境代理，无自动重试。超时返回504，其余云端失败返回502，只显示简短英文错误，不透传云端原始响应或凭据。30秒 socket 超时不是整体耗时的硬实时保证；主动重试可能产生新的调用费用。

新增接口的自动测试使用临时假凭据和模拟云响应，不代表实际 ASR 权限或树莓派部署已验证。更新树莓派时须同时复制 `speech.py` 并重启服务，再核对真实 iPad 录音与云端转写。参考：[阿里百炼录音文件识别（Qwen ASR）](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)。

### 语音部署验证（2026-10-21）

项目树莓派已更新 `server.py` / `speech.py` 并重启服务。经受信任 CA 与域名校验的 `https://work123.local:8443/api/transcribe` 返回 HTTP 200，合成中文短音频完整转写；未新增物品记录。更新前服务备份位于 `~/lost-found-box/backups/before-voice-20261021-092824/`。原生 iPad App 需用更新后的 Xcode 工程重新 Build/Run。

## 第一把门锁单次测试

当前接法为 **GPIO17 → S8050 NPN 三极管 → 5V LOW 触发继电器 IN1**。三极管会反相，因此 GPIO17 **高电平开锁、低电平关闭输出**；继电器板仍保持 LOW 触发。脚本发送一次约 0.5 秒的高电平脉冲，再恢复低电平。不要使用旧版“GPIO 直接接 LOW 触发继电器”的脚本，其 `--off` 输出高电平，在现在的三极管接法下会吸合继电器。

接线前提：树莓派物理第 11 针（BCM GPIO17）经 1kΩ 电阻接 S8050 的 B；10kΩ 电阻接在 B 与 E 之间；E 接公共 GND，C 接继电器 IN1。三极管的 B/C/E 按实际器件引脚确认。树莓派物理第 6 针 GND、继电器 DC−、外接 5V 电源负极共地。继电器 DC+ 接外接 5V，树莓派继续通过 USB-C 供电，不把两路电源的正极并联。锁使用外接 5V 电源和 COM1/NO1 常开触点；继电器板的供电端子按该板说明连接。

更新树莓派上的脚本后，在树莓派终端执行：

```bash
# 只检查型号与引脚占用，不驱动继电器
python3 ~/lost-found-box/tools/test_lock_once.py

# 第一把锁通电一次：GPIO17 高电平约 0.5 秒，随后恢复低电平
python3 ~/lost-found-box/tools/test_lock_once.py --fire

# 只关闭输出：GPIO17 设为低电平，不发送开锁脉冲
python3 ~/lost-found-box/tools/test_lock_once.py --off
```

程序使用树莓派已安装的 `lgpio`，固定只控制 GPIO17；同一脚本同时只能运行一个开锁测试，两次开锁测试至少间隔 30 秒，不自动重试。输出以 LOW 初始化并设置 `SET_PULL_DOWN`，不使用 `SET_ACTIVE_LOW`。退出、Ctrl+C 和可捕获的终止信号会尝试停止脉冲并恢复 LOW。`--off` 不受冷却限制；引脚被其他程序占用时会拒绝操作。

日志中的 `trigger: HIGH`、`gpio_samples` 和 `final_level: 0` 表示 GPIO17 的物理电平；`relay_trigger: LOW` 表示三极管后方继电器 IN1 的触发极性，`driver: S8050` 标识当前接法。程序没有测量 IN1 或锁状态，GPIO 读回不能证明继电器已释放或门已打开。

10kΩ B–E 下拉用于 GPIO 输入或悬空时保持三极管关闭。软件控制仍不能替代硬件限时保护，也不保证系统冻结、SIGKILL 等故障下的关断。该锁通电释放、关门后机械锁定，不能靠持续通电保持开门。

2026-10-22 三极管接法更新记录：当时本机两份脚本与树莓派已同步，树莓派上 17 项模拟 GPIO 测试通过，包括单次脉冲后恢复 LOW、`--off` 不输出 HIGH、信号中断清理、异常清理、冷却限制和引脚占用保护。该次通过 `work123.local`（当时地址 `192.168.1.141`）完成部署，旧脚本备份于 `~/lost-found-box/backups/before-s8050-20261022-l5d1dmkv/old/`。部署后默认只读检查通过，`pinctrl get 17` 返回 `ip pd | lo`（输入、下拉、低电平）。该次没有执行真实 `--fire` 或 `--off`，未验收实物开锁与重新扣合；此后新增的两路门反馈见上文当前说明。

### 历史接法测试（不适用于当前三极管接法）

2026-10-21 更换继电器板后的测试：用户告知已接好并要求测试，脚本已更新并在树莓派执行一次；GPIO 采样记录 HIGH 在 0.4359 秒、LOW 在 0.9377 秒，约 0.502 秒后恢复低电平。随后 `pinctrl get 17` 确认引脚为 LOW。10 项模拟 GPIO 测试通过，包括默认只检查、单次脉冲、异常清理和立即重试的冷却限制。用户现场反馈锁弹开但仍不能重新扣住，开锁后释放供电的验收未通过。已要求断开外接锁电源，需核对新板实际型号、HIGH/LOW 跳线及 COM/NO/NC 接点后再试；3.3V 输入兼容性不代表 HIGH 触发。未接锁状态反馈，GPIO 读回不代表门锁状态。此脚本尚未接入网页或 AI 自动开锁。
