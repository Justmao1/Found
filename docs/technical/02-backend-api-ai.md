# 后端、数据模型、HTTP API 与 AI

[返回总览](README.md) · 更新：2026-10-22。本页描述项目中的实现，不替代供应商最新接口规范。

## 1. 服务结构

[server.py](../../lost-found-box/server.py) 使用 Python 标准库 `ThreadingHTTPServer`，负责 HTTP、校验、数据库和后台识别。当前后端要求 Python 3.10+；真实 GPIO 监测／控制另外依赖系统 `lgpio`。

| 模块 | 职责 |
| --- | --- |
| [vision.py](../../lost-found-box/vision.py)、[search.py](../../lost-found-box/search.py)、[speech.py](../../lost-found-box/speech.py) | 视觉标签、语义匹配和语音转写 |
| [lockers.py](../../lost-found-box/lockers.py) | 四格分配、开锁、访客确认和人工恢复 |
| [iot_admin.py](../../lost-found-box/iot_admin.py) | 管理员会话、设备指标、物品分页及管理概览 |
| [door_feedback.py](../../lost-found-box/door_feedback.py) | 01／02 锁扣输入的持续采样、独立去抖与新鲜度 |
| [vibration.py](../../lost-found-box/vibration.py) | GPIO21 震动事件与持久化报警 |

默认监听 `127.0.0.1:8080`；非 loopback 绑定需要证书与密钥。SQLite 连接启用外键，数据库使用 WAL。每次写入采用事务；上传与开锁请求的幂等边界彼此独立。后台识别一个 worker、队列上限 64；搜索和转写各有独立的并发上限 1。

## 2. 数据模型

默认数据库为后端目录下 `data/items.sqlite3`，与启动命令的工作目录无关，可用 `--data-dir` 改变。图片不以独立文件保存，原始字节位于 `items.image`。

| 表 | 关键字段 | 用途 |
| --- | --- | --- |
| items | id PK、request_id UNIQUE、fingerprint、created_at、note、mime_type、image BLOB | 照片、备注、UTC 时间、上传幂等 |
| recognitions | item_id PK/FK、result JSON 文本 | 标签缓存，包括 model 与 version |
| recognition_jobs | item_id PK/FK、state | pending/processing/failed/disabled/complete |
| compartments | id PK（01–04）、state、item_id UNIQUE/FK | 格口占用与物品归属 |
| item_storage | item_id PK/FK、status、compartment_id FK | 物品存储生命周期 |
| locker_operations | id PK、kind、item_id、compartment_id、state、error、outcome、created_at | 持久化操作意图和人工确认结果 |
| locker_pulses | compartment_id PK/FK、attempted_at | 每格的最近尝试时间与冷却 |
| manual_openings | id PK、compartment_id、state、reason、previous_slot_state、previous_item_status、previous_operation_id | 人工开门的幂等记录及原业务状态快照 |
| vibration_alerts | id PK、triggered_at、trigger_count、cleared_at | 至多 100 条报警记录和未清除报警 |

`locker_operations` 有两个部分唯一索引：同一物品、同一格口各最多一个 `state != completed` 的操作。增量建表保留已有照片；旧照片不会自动分配格口。物品的 API `status` 来自 item_storage，未进入该表的旧记录对外是 `recorded`，不是 items 表自身的列。

上传指纹为 MIME、备注和图片字节的 SHA-256。同 request_id + 相同内容返回已有记录；内容不同返回 409。新的 request_id 即使照片相同也可建立新记录。

## 3. 通用 HTTP 约定

- 默认真机基址 `https://work123.local:8443`。
- POST：`Content-Type: application/json`、`X-Requested-With: lost-found-box`，恰好一个有效 Content-Length，不接受 Transfer-Encoding。
- 提供 Origin 时必须与服务同源；原生客户端不带 Origin 可以访问。这不是身份认证，固定请求头也不是密钥。
- 请求体须是 UTF-8 JSON 对象。失败通常返回 `{"error":"简短英文提示"}`，不返回供应商原始错误和 API Key。
- GET 有对应 HEAD 行为。没有 `GET /api/items/<id>` 单物品路由，物品对象来自列表、保存、识别或格口操作响应。

### 公共对象

以下仅为格式示例，不对应真实库存：

```json
{
  "id": "11111111-1111-4111-8111-111111111111",
  "created_at": "2026-10-22T00:00:00.000Z",
  "note": "Found near the library",
  "image_url": "/images/11111111-1111-4111-8111-111111111111",
  "status": "stored",
  "compartment_id": "01",
  "recognition": {"tags": ["mug", "blue", "handle"], "model": "qwen3-vl-plus", "version": 3},
  "recognition_status": "complete"
}
```

recognition 和 compartment_id 可以为 null。Swift 客户端只解码所需字段，允许响应增加元数据。

### 路由表

| 方法和路径 | 请求 | 成功响应 |
| --- | --- | --- |
| GET `/api/health` | 无 | 200，`{ok:true}` |
| GET `/api/ai/status` | 无 | 200，`{configured,model}`；不验证额度/权限 |
| GET `/api/items` | 无 | 200，`{items,total}`，最新 100 条，包括历史状态 |
| GET `/api/items?available=1` | 无 | 200，同格式，仅 stored 且对应 occupied 的可领取物品 |
| GET `/images/<uuid>` | 无 | 200，JPEG/PNG 原始字节与相应 MIME；找不到为 404 |
| POST `/api/items` | `{request_id,image,mime_type,note}`，image 为纯 Base64 | 首次 201/重复 200，`{item,duplicate}` |
| POST `/api/items/<uuid>/recognize` | `{}` | 200，`{item}`；有效缓存直接复用 |
| POST `/api/search` | `{query}` | 200，`{matches:[{item,reason}],searched_count,pending_count}` |
| POST `/api/transcribe` | `{audio,mime_type:"audio/wav"}`，audio 为标准 Base64 | 200，`{text}` |
| GET `/api/lockers` | 无 | 200，`{enabled,driver,compartments,operations}` |
| POST `/api/locker-operations` | 严格 `{request_id,item_id,kind}` | 首次 201/重复 200，`{operation,item}` |
| GET `/api/locker-operations/<uuid>` | 无 | 200，`{operation,item}`；不再次开锁 |
| POST `/api/locker-operations/<uuid>/complete` | 严格 `{}` | 200，`{operation,item}`；物理完成确认 |
| POST `/api/locker-operations/<uuid>/resolve` | 严格 `{outcome}` | 200，`{operation,item}`；人工核实，不触发 GPIO |

静态白名单包含旧照片网页 `/`、`/app.js`、`/style.css`，以及管理页 `/admin`、`/admin/`、`/admin/admin.js`、`/admin/admin.css`；不公开 config、certs、data。格口操作结构及状态见[硬件与状态机](03-hardware-locker-flow.md)。

### 管理台认证与路由

管理台是英文界面，使用独立站点密码和服务端内存会话；不是每位访客的用户账户。`tools/configure_admin.py` 配置 12–256 字符密码，默认写入权限 600 的 `config/admin-password.txt`。服务启动时读取，更换密码后重启；重启会使旧会话失效。`LOST_FOUND_ADMIN_PASSWORD_FILE` 可覆盖路径。

会话有效期 8 小时，Cookie `found_admin` 使用 `Path=/api/admin`、HttpOnly、SameSite=Strict；HTTPS 附加 Secure。浏览器不保存密码。来源 IP 在五分钟窗口内累计 10 次失败登录后受到限制。未配置密码时登录返回 503。

除 session 查询和 login 外，下列接口要求管理会话；POST 同时保留通用 JSON、同源及固定请求头约定，最大 16 KiB。**这些登录保护仅覆盖 `/api/admin/`，公开访客接口及兼容 `/api/locker-operations/<uuid>/resolve` 仍未要求后台会话。** 原生 App 的 Staff 设备认证与此网页密码也不是同一套认证。部署边界仍是可信局域网。

| 方法和路径 | 请求 | 成功响应／用途 |
| --- | --- | --- |
| GET `/api/admin/session` | 无 | 200，`{configured,authenticated}` |
| POST `/api/admin/login` | `{password}` | 200，`{authenticated:true}` 和会话 Cookie |
| POST `/api/admin/logout` | `{}` | 200，`{authenticated:false}`，注销当前会话 |
| GET `/api/admin/overview` | 无 | 200，设备指标、库存、四格、待处理操作、近期活动及震动状态 |
| GET `/api/admin/items?q=&status=&offset=0&limit=25` | 搜索、状态及分页参数 | 200，`{items,total,offset,limit}` |
| POST `/api/admin/manual-open` | `{request_id,compartment_id}`；兼容可选 reason | 首次 201／重复 200，`{operation,duplicate}` |
| GET `/api/admin/manual-open/<uuid>` | 无 | 200，`{operation}`，只查询原开门请求 |
| POST `/api/admin/manual-open/<uuid>/confirm` | `{}` | 200，`{operation}`，完成异常／旧版待确认人工开门 |
| POST `/api/admin/locker-operations/<uuid>/resolve` | `{outcome}` | 200，`{operation,item}`，核实后的库存处置 |
| POST `/api/admin/items/<uuid>/recognize` | `{}` | 202，`{queued:true,item_id}`，入队后由概览／物品列表读取结果 |
| POST `/api/admin/vibration/clear` | `{alert_id}` | 200，`{vibration}`，清除指定报警 |

管理页可见时每 3 秒轮询概览，网络失败标记过期并停用开门控件。设备指标按访问采样，最近 120 点仅保存在内存；不支持的指标为 null。门输入与震动监测独立持续运行，不依赖网页是否打开。

点击格子上的 **Open** 即发送一次开门请求，不填原因、不重复确认。成功提示 **Opening command sent**，自动恢复原软件格口状态，保留库存和访客存取记录。浏览器保存请求 UUID；丢失响应时查询原请求，显式重试使用同一编号。异常开门用 **Finish** 结束原操作，不再次发脉冲，不表示物品已领取或门已关闭。详细字段见[管理台接口](../iot-admin-contract.md)。

### 容量和校验

| 输入 | 限制 |
| --- | --- |
| 图片 | JPEG/PNG，二进制最大 5 MiB；上传 JSON 最大 8 MiB |
| 备注 | 最多 200 Python 字符/Unicode 码点 |
| 搜索描述 | 去首尾空白后 1–500 码点，JSON 最大 16 KiB |
| 检索库存 | 最多 200 条有效标签记录，超过拒绝，不能默默只搜部分 |
| 搜索候选 | 最多 5 条，理由 1–200 字符，拒绝重复或无效 ID |
| 标签 | 1–5 个唯一非空短标签，每个最多 24 字符，无控制字符 |
| 录音 | 16 kHz、单声道、16-bit PCM WAV，0.3–30.5 秒；文件最多 1,000,000 字节 |
| 转写 JSON | 最大 1,400,000 字节；结果去首尾空白后 1–500 码点 |
| 格口请求 | JSON 最大 16 KiB，规范小写连字符 UUID，kind 为 deposit/retrieve |

图片校验检查容器结构与尺寸，不进行完整像素解码。语音严格校验 Base64、RIFF 块、PCM 元数据、帧数与真实字节长度。

### 主要错误码

| 状态码 | 常见含义 |
| --- | --- |
| 400 / 415 | 参数、图片/录音结构、JSON、长度格式或 Content-Type 不合法 |
| 401 | 管理会话缺失／过期，或管理员密码错误 |
| 403 | 来源或固定请求头不满足约定 |
| 404 | 不存在的物品图片、操作或路径 |
| 408 | 请求读取超时/连接丢失，不等于没有发生副作用 |
| 409 | 幂等内容冲突、格口满、生命周期/归属冲突、不能普通确认 uncertain、门未关好／仍在去抖 |
| 413 | 媒体、请求体或检索库存超过上限 |
| 422 | 未识别到可用语音或转写长度超出范围 |
| 429 | 指定锁冷却中，或所有可用空格仍在冷却 |
| 500 | 本地保存失败，需要核查原请求结果 |
| 502 / 504 | 云服务失败/无效响应，或等待超时 |
| 503 | 未配置、硬件停用/不可用、门反馈不可用、识别队列满或搜索/语音忙 |

成功 HTTP 状态不等于实物成功：格口响应中的 `operation.state` 可能是 `uncertain`，客户端必须检查状态。

## 4. 视觉识别

照片事务先提交，后台再识别；AI 失败不撤销照片。模型默认 `qwen3-vl-plus`，通过配置的 `/compatible-mode/v1/chat/completions` 接口接收 Base64 图片。视觉请求不发送备注。

提示要求只识别主体，第一个标签是具体类别，之后是颜色、形状、显著特征；要求英文，不要长句、OCR、背景描述或个人字段。服务端严格验证 JSON 结构、数量、长度和重复项；**英文语义和不含个人信息主要依赖提示，当前没有独立语义过滤器**。

识别结果缓存 version=3，同物品并发调用共享 Future。轮询读取状态不会重复收费；显式重试可能产生新调用。启动时清理遗留 pending/processing，再从最新最多 100 条非 failed 记录中补充有界队列；超出队列容量的记录需后续重试。旧版本长描述/中文缓存不视为当前有效缓存。

供应商请求使用 30 秒 socket timeout，最多读取 64 KiB 响应，禁止重定向和环境代理。`recognize` HTTP 等 Future 最长 35 秒，超时不撤销已在后台运行的任务。客户端等待为 45 秒。这些不是整条业务的硬实时保证。

## 5. 自然语言匹配

`search.py` 使用同一配置中的模型，当前不是 embedding、向量库或 OpenCV 图像相似度。

1. 根据格口模式和库存状态选取可搜索物品。
2. 只取有效标签和备注；无标签的合格记录计入 pending_count。
3. 为本次候选生成临时整数序号 1…N，将描述、序号、标签和备注交给模型。真实 UUID 和照片不随本次搜索发送。
4. 验证输出中整数序号范围、唯一性和理由，再映射回真实记录。
5. 云调用返回后重新检查物品和格口状态，剔除等待期间已经取走的物品。

开启格口时仅检索 stored+occupied；关闭格口时额外保留未进入 item_storage 的旧照片。曾被格口管理但已领取/待确认/待核查的记录不会因关闭硬件而重新出现。`available=1` 列表始终只有 stored+occupied，不等同于 disabled 模式下的 legacy 搜索范围。

无候选时返回空 matches，不必调用云模型；`configured:true` 不是权限验收。查找只返回候选，不修改库存或发出开锁。备注和描述作为不可信数据，不作为系统指令。

## 6. 语音转写与数据去向

`speech.py` 复用服务端 Key 与北京域名，调用 `/api/v1/services/aigc/multimodal-generation/generation`，固定模型 `qwen3-asr-flash`，不使用视觉 model 字段。Key 需要相应模型权限。转写只返回文本，不自动搜索。

| 数据 | 保存/发送位置 |
| --- | --- |
| 物品照片 | SQLite 持久化；识别时发送百炼 |
| 标签 | SQLite；匹配时发送百炼 |
| 备注、搜索描述 | 备注在 SQLite；匹配时两者发送百炼 |
| 录音 | iPad 临时录制；上传前清理临时文件；后端内存处理并发送百炼 |
| 转写结果 | 交回客户端编辑，不写入本项目后端数据库或音频文件 |
| API Key | 后端配置/环境变量，不发送 iPad，不出现在业务响应 |

服务器不保存录音和转写日志，不等于云服务不处理/不保留数据；供应商政策需按其服务条款核对。

## 7. AI 配置

优先使用 `python3 tools/configure_ai.py` 隐藏输入 Key。默认文件 `config/ai.json`，权限 600，字段为 `api_key`、`model`、`base_url`。`LOST_FOUND_AI_CONFIG` 可指定文件；`DASHSCOPE_API_KEY` 覆盖文件中的 Key。

默认 base_url 为 `https://dashscope.aliyuncs.com/compatible-mode/v1`；代码只允许它或符合 `<workspace>.cn-beijing.maas.aliyuncs.com` 的 HTTPS 域名，端口 443/默认，路径固定。不是任意 OpenAI-compatible 服务都能直接替换。

供应商参考入口（来自原项目文档，本次未重新进行网页时效核验）：[视觉理解](https://help.aliyun.com/zh/model-studio/vision)、[兼容 Chat API](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions)、[Qwen ASR](https://help.aliyun.com/zh/model-studio/qwen-asr-api-reference)。

## 8. 门反馈与震动数据

01 反馈为 BCM GPIO12／物理 32，02 为 BCM GPIO18／物理 12；各自的干接点另一端接 GND，输入内部上拉，LOW 为锁扣扣住，HIGH 为打开。每 50 ms 采样、各自稳定 250 ms 后确认状态，采样超过 1 秒未更新则 unavailable。03／04 为 `not_configured`，继续人工确认。这里测量锁扣状态，不检测格内物品；开锁输出 17／26／13／5 与这些输入分开。

公开 compartment 和 visitor operation 都携带 `door`，管理概览另外以 `door_state` 镜像其 state：

```json
{"enabled":true,"gpio":18,"pin":12,"state":"closed","level":0,"updated_at":1792670400.0,"error":null}
```

state 为 `closed`、`open`、`unknown`、`unavailable` 或 `not_configured`。enabled／capabilities 表示已配置监测，不证明接线连续性；断线 HIGH 不能与开门区分。普通 `/complete` 仅接受传感器格口的当前 closed：open／unknown 返回 409，unavailable 返回 503，均保留物品和格口状态。已完成请求可幂等重放，不因门后来打开而回退；明确的 staff resolve 可在核实后处理异常。**关门只更新门状态，仍须访客确认已放入／取走才修改库存。** 详见[门反馈](../door-feedback.md)。

GPIO21／物理 40 为整柜震动输入，活动电平 HIGH；两次计数至少间隔 100 ms，2 秒内 5 次触发形成报警。开锁前抑制计数 2 秒，以过滤锁体动作。报警和未清除状态持久化，运行累计计数在重启后归零；不驱动锁、不自动改变库存。

概览的 `vibration` 包含监测状态、输入电平、最近／累计次数、最后触发时间、active_alert 和最近 20 条 events。管理页收到新报警显示明显的 **Shaking detected** 弹窗；**Dismiss**／Escape 仅关闭弹窗，**View alert** 可重开，**Clear alert** 才清除指定报警。旧 ID 不会清除较新报警。完整响应及接线见[震动监测](../vibration-monitoring.md)。
