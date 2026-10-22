# Found IoT 管理台

管理网页与 iPad 共用树莓派上的同一个服务、SQLite 数据库和四格控制器。入口为 **https://work123.local:8443/admin/**；原 iPad 接口和照片登记页继续使用。

## 页面能力

- 运行概览：CPU 使用率、内存、磁盘、CPU 温度、负载、系统和服务运行时间、IP、网络收发流量，以及 API、数据库、HTTPS、AI 队列状态。
- 最近趋势：每 3 秒采样，在内存保留最近 120 个采样点。服务重启后从头积累；无人访问时不采样，不补造历史。Linux 不支持的指标显示“未提供”。
- 震动监测：GPIO21 输入状态、最近两秒触发数、本次运行累计、最近触发时间和报警记录；连续震动报警后可直接点击 **Clear alert**，详见 [vibration-monitoring.md](vibration-monitoring.md)。
- 四格状态：软件分配状态、关联物品、BCM / 物理针号、GPIO 采样电平、开锁冷却时间、未完成操作。
- 物品记录：照片、标签、备注、登记时间、格号、入柜/领取状态；服务端搜索、过滤和分页；失败识别可重试。
- 操作记录：最近 50 条存入、领取和人工开门记录，包含操作编号、时间、状态与异常；兼容历史记录里的开门原因。

**没有门磁、物品重量或在位传感器。** 门的实际开闭、物品实际在位均无法直接测量。GPIO 电平和开锁命令完成仅说明电气控制情况，接口将物理门状态标为“未知”，界面不重复显示传感器说明。访客存入和领取仍通过点击完成确认。

## 初次设置和修改密码

在树莓派的项目目录运行：

```sh
cd ~/lost-found-box
python3 tools/configure_admin.py
systemctl --user restart lost-found-box.service
```

交互输入 12–256 字符的站点管理员密码，不通过命令参数或日志传递。密码文件默认为 `config/admin-password.txt`，仅文件所有者可读写；可用环境变量 `LOST_FOUND_ADMIN_PASSWORD_FILE` 指定其他路径。自动安装可执行 `python3 tools/configure_admin.py --generate`；它仅在文件不存在时写入随机密码，不将密码打印到日志。管理员可在自己的终端读取受保护文件。

服务启动读取密码，修改后需重启。每次重启会使旧会话失效。会话有效期 8 小时，使用 HttpOnly、SameSite=Strict Cookie，HTTPS 上附加 Secure 属性。浏览器不保存密码。连续 10 次失败登录限制该来源 IP 五分钟。未配置密码时管理接口拒绝访问。

管理台的登录保护只覆盖 `/api/admin/`。原 iPad / 演示接口仍按可信局域网设计，**整个服务不应直接开放到公网**。如需公网管理，应另行实现全接口鉴权、访问隔离和正式域名 TLS。

## 手动开门

点击对应格子卡片上的 **Open** 即可开门，不需要填写原因、勾选或再次确认。按钮发送期间显示 **Opening…**，成功后短暂提示 **Opening command sent**，操作自动结束。

手动开门保持物品和原有存入／领取记录不变。服务仅在发送脉冲期间暂时占用格子，成功后自动恢复原来的软件状态。未完成的访客存入／领取仍在 Pending actions 中按实际情况处理；这类修改物品记录的操作只保留一个简短确认，没有填写项。

每次开门发出一次 0.5 秒脉冲，硬件模式每格冷却 30 秒。请求编号自动生成并保存在浏览器中；响应丢失后查询原请求，Retry 使用同一编号，后端不会重复产生脉冲。异常或中途重启的操作显示在 Pending actions，点击 **Finish** 保持原有物品记录并结束该操作。此操作不再次开锁，也不代表测量到了门已关闭。

01→GPIO17（物理11）；02→GPIO26（37）；03→GPIO13（33）；04→GPIO5（29）。四路均为 S8050＋LOW 触发继电器，GPIO HIGH 激活。GPIO5 不作为反馈输入。页面不提供任意 GPIO 或脉冲时长配置。

## 本机开发和验证

```sh
cd lost-found-box
python3 tools/configure_admin.py
python3 server.py --host 127.0.0.1 --port 8080 --locker-mode simulated
```

访问 `http://127.0.0.1:8080/admin/`。模拟模式只允许回环地址，页面会标识模拟控制；不会加载 GPIO 驱动。默认硬件关闭。Linux 之外不可用的 `/proc` 和温度指标为 null。

```sh
python3 -m unittest discover -s tests -v
node --check static/admin.js
# 从仓库根目录运行真实 Swift 客户端集成检查
python3 Tools/verify_locker_integration.py
```

接口字段见 [iot-admin-contract.md](iot-admin-contract.md)。部署时保留 `data/`、`config/`、`certs/`，备份 SQLite 后更新代码并重启服务。只读健康和管理概览检查不会触发继电器。四把锁的实际机械动作需在现场逐格验收。
