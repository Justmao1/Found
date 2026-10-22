# 开发、部署、新设备连接与维护

[返回总览](README.md) · 更新：2026-10-22。以下为操作手册，本次文档整理未执行远程部署。命令中的路径需区分开发仓库和树莓派运行目录。

## 1. 环境与地址

| 项目 | 约定 |
| --- | --- |
| 开发 | macOS + Xcode；Python 3.10+；Node 仅用于网页语法／测试检查 |
| 树莓派 | Raspberry Pi 4B，现有 Linux/Python；gpio 模式额外使用系统 lgpio |
| SSH | `ssh wlb123@work123.local`；认证凭据不写入文档 |
| 部署目录 | `/home/wlb123/lost-found-box` |
| 业务入口 | `https://work123.local:8443` |
| 英文 IoT 管理页 | `https://work123.local:8443/admin/`，独立站点管理员密码 |
| 公开 CA 安装页 | `http://work123.local:8088`，不提供库存/API |
| 本机开发 | `http://127.0.0.1:8080` |

历史 IP：10 月 13 日 `192.168.5.3`，10 月 22 日记录为 `192.168.1.141`，都不保证现在仍有效。优先使用主机名；需 IP 时在 Pi 执行 `hostname -I`。新网络要允许设备互访，访客 Wi-Fi 的客户端隔离可能阻止连接。

## 2. 开发电脑运行

下列命令从 Git 仓库根目录 `Lost&Found/` 执行，不是外层课程文件夹：

```sh
cd lost-found-box
python3 server.py --host 127.0.0.1 --port 8080 --locker-mode disabled
```

默认使用该后端目录的 data 和 AI 配置；已配置 Key 的服务可能自动识别已有未完成记录。纯离线调试应使用独立空配置和临时数据库，且不继承环境 Key：

```sh
# 仍在 lost-found-box/，退出测试后只清理该临时目录
found_demo_dir=$(mktemp -d)
printf '{}\n' > "$found_demo_dir/ai.json"
env -u DASHSCOPE_API_KEY LOST_FOUND_AI_CONFIG="$found_demo_dir/ai.json" \
  LOST_FOUND_DOOR_FEEDBACK_ENABLED=0 LOST_FOUND_VIBRATION_ENABLED=0 \
  python3 server.py --host 127.0.0.1 --port 8081 \
  --data-dir "$found_demo_dir/data" --locker-mode simulated
```

门反馈和震动开关独立于 locker-mode，离线运行显式设为 0 可避免继承现场环境。模拟模式没有云标签时不能凭空完成入柜前置条件。需要完整离线格口演示数据时，回到仓库根目录运行 `python3 Tools/verify_locker_integration.py`；该脚本提供隔离 fixture、模拟识别和搜索，不把 fixture 写进真实库存。

## 3. 新 iPad 连接

1. iPad 与 Pi 连接可互通的局域网，Pi 服务运行中。
2. 将项目**公开 CA** `certs/ca.crt` 安装到 iPad，开启完全信任。可用 8088 安装页或传送公开证书，不能传 server.key/ca.key。
3. 通过 Xcode 安装当前原生 App（需签名）；原生 App 安装与 Safari 打开网页是两条不同入口。
4. 在 App 的 Staff 认证后进入 Connection & device setup，Campus server 填 `https://work123.local:8443`，保存并检查。
5. 允许本地网络权限；相机和麦克风在首次使用时授权。连接成功后分别做拍照、转写及保存验收。
6. 固定站点由工作人员设置 Guided Access，并限制设备密码/生物识别给工作人员使用。

仅需兼容照片网页时在 Safari 打开同一 HTTPS 地址；网页不提供原生四格口流程。远程 HTTP 不适用于此部署。不能用关闭 TLS 校验或忽略证书警告替代安装和信任 CA。

## 4. 证书与 AI 配置

证书工具依赖 OpenSSL。以下从后端源码目录执行，hostname 应与实际访问名一致：

```sh
python3 tools/make_tls.py --hostname work123.local
```

要用 IP 访问时添加实际 `--ip`。已有项目 CA 时，续签服务器证书使用相同输出目录和 `--renew`，保留 CA；不要无故生成另一套 CA 导致全部 iPad 失去信任。工具生成的服务器证书期限为 90 天，现场可只读核对：

```sh
openssl x509 -in certs/server.crt -noout -dates -ext subjectAltName
```

Pi 需要 server.crt/server.key；8088 公开安装页另外需要 ca.crt；CA 私钥留在签发机器，不上传 Pi 或分发给组员设备。

AI 配置在 Pi 终端隐藏输入：

```sh
python3 ~/lost-found-box/tools/configure_ai.py
```

默认 `config/ai.json`，权限 600。可以配置北京地域 base_url、模型和 Key；不要把 Key 粘贴进命令参数、截图或文档。每次请求动态读取配置，无需为更换 Key 修改客户端。`configured:true` 只表示本地格式有效，要验证权限须另行进行获授权的真实调用。

管理密码另外配置：

```sh
python3 ~/lost-found-box/tools/configure_admin.py
systemctl --user restart lost-found-box.service
```

工具交互输入 12–256 字符密码，默认存入权限 600 的 `config/admin-password.txt`；`LOST_FOUND_ADMIN_PASSWORD_FILE` 可覆盖路径。服务启动时读取，修改后必须重启，已有网页会话随重启失效。浏览器访问 `/admin/` 后登录，会话有效期 8 小时；这里的密码与 iPad Staff 设备认证、AI Key 分开。管理登录只覆盖 `/api/admin/`，兼容访客接口仍按可信局域网使用。

## 5. 服务安装与更新步骤

系统使用用户级服务：[主服务](../../lost-found-box/deploy/lost-found-box.service)、[证书门户](../../lost-found-box/deploy/lost-found-setup.service)。示例路径为 `%h/lost-found-box`，如果直接在 Git 克隆目录运行，要先改成实际路径。

更新前确认没有正在进行的存物/取物，记录待处理操作并备份代码和数据。既有 deployment 目录更新时保留 config、certs、data，不能用整目录覆盖或带 `--delete` 的同步清掉它们。

建议顺序：

1. 在开发电脑运行[验证命令](05-verification-roadmap.md)。
2. 在 Pi 停服务，做一致性备份，见下一节。保留原服务文件和硬件配置。
3. 上传同一版本 `server.py`、`vision.py`、`search.py`、`speech.py`、`lockers.py`、`iot_admin.py`、`door_feedback.py`、`vibration.py` 和 `static/`；需要时同步 tools、tests、deploy。这些模块由服务直接 import，漏传会导致启动失败；开锁驱动另依赖 `tools/test_lock_once.py`，首次安装须一并复制 tools。
4. 首次安装时生成/安装证书，建立 AI 配置及管理密码，检查路径和权限。
5. 安装/更新用户级 service，重载，再启动；先核对健康与配置，之后另行安排真实业务验收。

在树莓派：

```sh
mkdir -p ~/.config/systemd/user
cp ~/lost-found-box/deploy/lost-found-box.service ~/.config/systemd/user/
cp ~/lost-found-box/deploy/lost-found-setup.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now lost-found-box.service lost-found-setup.service
systemctl --user status lost-found-box.service lost-found-setup.service --no-pager
```

新站点需检查 `loginctl show-user "$USER" -p Linger`，需脱离 SSH 长期运行时由设备管理员启用该用户 linger；历史项目 Pi 已有启用记录。不要同时再手动启动同端口 server.py。

主 service 以 `EnvironmentFile=-%h/lost-found-box/config/lockers.env` 可选加载硬件模式。没有该配置时默认 disabled。`deploy/lockers.env.example` **会启用真实 gpio**，不能当作普通安装文件无条件复制；只有现场核对四路接线、极性和引脚后才采用。[硬件文档](03-hardware-locker-flow.md)说明具体前提。

当前展示接线的配置如下；修改后需重启主服务。示例文件的反馈开关默认为 0，且未预置震动开关，现场应明确设置：

```sh
LOST_FOUND_LOCKER_MODE=gpio
LOST_FOUND_LOCKER_GPIO_MAP=01=17,02=26,03=13,04=5
LOST_FOUND_DOOR_FEEDBACK_ENABLED=1
LOST_FOUND_VIBRATION_ENABLED=1
```

反馈启用后同时监听 01 的 GPIO12（物理 32）与 02 的 GPIO18（物理 12），内部上拉、干接点接 GND、LOW 表示扣住。03／04 仍人工确认。震动输入 GPIO21（物理 40）为 HIGH 触发。两种监测均在后台持续运行，即使无人打开管理页；故障显示 unavailable，不用开锁输出来推断门状态。启用传感器需要系统 `lgpio` 和相应引脚访问权限。

## 6. 只读健康检查

在 Pi 的后端目录，指定受信任项目 CA，不使用 `-k`：

```sh
curl --noproxy '*' --cacert certs/ca.crt https://work123.local:8443/api/health
curl --noproxy '*' --cacert certs/ca.crt https://work123.local:8443/api/ai/status
curl --noproxy '*' --cacert certs/ca.crt https://work123.local:8443/api/lockers
systemctl --user status lost-found-box.service --no-pager
journalctl --user -u lost-found-box.service -n 80 --no-pager
```

健康返回 ok 只证明 HTTP 服务可响应；AI status 不证明模型权限；lockers.enabled 不证明继电器接线或实际柜门正确。格口 GET 不发脉冲，但可能在硬件空闲时把遗留操作修复为待检查状态，属于恢复元数据。

在管理页登录后可只读核对门反馈、震动状态、库存和设备指标；此时不点击 **Open**。01／02 的 `door.state` 应随锁扣显示 closed／open，变动初期短暂 unknown，采样失效为 unavailable；03／04 应为 not_configured。前台管理页约每 3 秒刷新，iPad 存取页前台约每秒读取原操作。关门后仍须用户确认物品已放入／取走，不能以接口连通或门已关好代替物品确认。

传感器现场验收可分别切换 01／02 锁扣，确认另一格读数不串扰；轻敲盒体检查 **Shaking detected** 弹窗，**Dismiss** 后报警保留，**Clear alert** 后清除。这些检查不需要发出开锁请求。2026-10-22 用户已分别确认 01 和 02 状态在 iPad／后台正确变化；这是当时验收记录，不代表之后接线无需检查。

## 7. 备份与回滚

以下在 Pi 执行，需先暂停现场使用。正常停止服务后复制整个 data，保留可能存在的 WAL/SHM，并备份配置与源码；备份含照片和凭据，限制权限，不上传公开仓库。

```sh
cd ~/lost-found-box
systemctl --user stop lost-found-box.service
found_backup_dir="backups/manual-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$found_backup_dir"
chmod 700 "$found_backup_dir"
cp -a data "$found_backup_dir/"
cp -a server.py vision.py search.py speech.py lockers.py iot_admin.py door_feedback.py vibration.py \
  static tools deploy "$found_backup_dir/"
# config、certs 如存在，也应以同等私密权限单独备份
systemctl --user start lost-found-box.service
```

已有四格口数据后不能盲目回滚成只认照片的旧版本。恢复数据库前先核对实物格口：旧备份可能不知道备份之后的存入/领取，直接覆盖会导致物品归属错误。恢复步骤应是停服、保留当前副本、恢复兼容版本、现场逐格核查，再启动验收。不得恢复旧极性诊断脚本去驱动当前 S8050 接法。

## 8. 常见故障

| 表现 | 优先检查 | 不应采取的捷径 |
| --- | --- | --- |
| work123.local 无法解析 | Pi 电源、同网、mDNS、实际 IP、无线隔离 | 直接认定历史 IP 仍有效 |
| Safari 能访问，App 不通 | 本地网络权限、App 地址、CA 完全信任、TLS 主机名 | 禁用系统证书验证 |
| TLS 失败 | 证书期限、SAN、访问名、CA 是否同一套 | 以 `curl -k` 宣称 HTTPS 验收通过 |
| 照片保存成功但无标签 | ai/status、有效 Key/模型、识别 failed/busy、云网络 | 重新保存同一照片来重试识别 |
| 无搜索候选 | 是否 stored、标签是否就绪、库存范围、描述是否矛盾 | 把 no match 当网络故障或编造结果 |
| 语音 400/413/422 | WAV 规格、时长/大小、空音频或过长转写 | 修改 MIME 来绕过实际格式校验 |
| 格口 409/429 | 容量、未完成操作、归属、冷却 | 改 request_id 连续开锁 |
| 格口 uncertain/响应丢失 | 查询原操作，Staff 核实物品和门 | 自动释放格口或重放脉冲 |
| “I found something” 显示 Continue compartment step | 点击继续原步骤；awaiting_confirmation 会恢复门状态和完成按钮 | 重新分配格子或重发开门请求 |
| 门已关好但无法完成 | 01／02 的 door.state、LOW 接点、GND、采样新鲜度；网络恢复后查询原操作 | 用开锁输出 LOW 当作门已关好 |
| 02 操作受 01 门影响 | 核对 01=GPIO12、02=GPIO18；当前后端使用独立采样／去抖 | 将两根反馈并接或改成共享门状态 |
| 管理页无法登录／会话失效 | 密码配置路径、服务是否已重启、8 小时会话时限 | 将 AI Key 当管理密码 |
| 震动显示 Unavailable／无弹窗 | GPIO21 接线、电源、开关、监测状态、最近计数；开锁后 2 秒抑制窗口 | 从未出现报警推断传感器正常 |
| 继电器一直吸合/锁不复扣 | 外部电源、IN 极性、NPN、COM/NO、机械结构 | 延长通电或循环尝试 |

## 9. 交接最少资料

交接仓库版本、部署路径、受控配置保管位置、公开 CA、主机名、四格输出和两路反馈／震动 GPIO 表、管理密码的保管方式、备份记录、已知未完成操作和现场验收结果。不要用聊天记录里的旧密码、旧 IP、旧接线图充当可复现部署文档。
