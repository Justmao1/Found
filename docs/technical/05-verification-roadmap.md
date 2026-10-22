# 验证矩阵、当前进度与下一步

[返回总览](README.md) · 更新：2026-10-22（Asia/Shanghai）。功能基线：`e722f21`。

## 1. 最近验证结果

以下汇总各次功能实现时已运行的检查。本次只修订文档并核对源码、已有日志和链接，没有重新运行应用测试、部署服务、调用云模型或操作实物锁。

| 检查 | 最近结果与范围 | 证据 |
| --- | --- | --- |
| Python unittest | 196 项通过；涵盖后台会话、人工开门、震动、两路独立门反馈、四格状态及故障处理 | 10-22 两路反馈更新；[后端记录](../../lost-found-box/VERIFICATION.md) |
| Swift Package | 44 项通过；核心模型、网络和门反馈可选字段兼容 | 10-22 首路反馈更新；[原生记录](../../verification/README.md) |
| 原生 XCTest | 62 项通过、0 失败；含首页续办、已完成日志清理、未知结果保留、门反馈与会话隔离 | 10-22 21:24，`e722f21` |
| Swift → Python 四格联调 | 13 项真实本机 HTTP 检查通过，恰好 10 次模拟开锁 | 10-22 21:12；[联调脚本](../../Tools/verify_locker_integration.py) |
| 签名真机构建 | Build 成功；安装并启动于 iPad Pro 11 英寸第 4 代 | 10-22 最新首页续办版本 |
| iPad 模拟器交互 | 首页继续 02 → 开门状态禁用完成 → 关闭状态启用 → 明确确认 → 返回首页 → 新登记可拍照 | 独立测试服务，审计仅一次 `/complete` POST、无开锁 POST |
| 基础 HTTP / Node 相机 | 此前分别 12 项与 2 项通过；本次未重跑 | 10-22 约 14:35，初始四格版本记录 |

原始运行产物保留在本机 `verification/door-feedback/`、`verification/two-door-feedback/`、`verification/report-button-recurrence/`；这些目录被 Git 忽略。仓库保留上述摘要、[原生验证记录](../../verification/README.md)、[后端验证记录](../../lost-found-box/VERIFICATION.md)和可复现测试源码，不提交设备标识、库存快照或凭据。

各套测试的数量对应各自最近一次运行，不表示全部在同一提交同一时刻重跑。自动测试使用临时数据库、模拟输出和假传感器，不代表真实机械动作或云端识别质量。

## 2. 部署与现场证据

| 能力 | 已有证据 | 验证边界 |
| --- | --- | --- |
| 四格后端 | 10-22 已部署，`driver=gpio`；SQLite、HTTPS 和四路空闲 LOW 检查通过 | 初始四格记录为部署时快照，不是当前库存 |
| 英文管理台 | 已实现并部署；遥测、物品列表、一键 Open、Cookie 登录、震动弹窗和门状态共用后台 | 模拟开门与接口检查不替代四把实体锁验收 |
| 01 门反馈 | GPIO12／物理 32，LOW 已扣住；用户确认 iPad 随锁扣变化 | 仅锁扣状态，不检测物品在位 |
| 02 门反馈 | GPIO18／物理 12；两路更新已部署，公共和管理 API 一致；用户确认界面正确变化 | 两路独立采样，不能用 01 的关闭代替 02 |
| iPad 入口恢复 | 最新版本已构建、安装并启动；62 项原生测试和模拟器续办闭环通过 | 最新修复后的完整真实存入／领取仍需现场逐步确认 |
| 照片、视觉与搜索 | 10-13/14 有实际照片、HTTPS、百炼识别和库存搜索记录 | 旧浏览器实测不等于当前原生端所有权限和相机路径验收 |
| 语音 | 10-21 树莓派真实转写接口和合成中文音频通过 | 不等于现场噪声下 iPad 麦克风准确率评估 |
| 无人值守 | systemd 配置与历史服务重启持久化验证 | 尚无整机掉电、全部格口盘点和完整恢复验收记录 |

两路反馈部署备份：`~/lost-found-box/backups/two-door-20261022-211427`。首路反馈备份：`~/lost-found-box/backups/door-20261022-204337`。这些是站点本地目录，GitHub 不包含源码以外的数据库、配置或私钥备份。

01／02 为本次展示的反馈格口；03／04 的开锁输出仍保留，但没有接门反馈。用户确认锁扣变化的证据与自动模拟门状态的证据分开记录，不据此宣称四路完整物理闭环均已通过。

## 3. 复现命令

在仓库根目录执行（后端 Python 3.10+）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 Tools/verify_api_integration.py
python3 Tools/verify_locker_integration.py
```

在 `lost-found-box/` 执行：

```sh
python3 -m unittest discover -s tests -q
node --test tests/test_camera.js
node --check static/app.js
node --check static/admin.js
```

原生构建与 XCTest（回到仓库根目录，按本机可用模拟器调整名称）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Lost&Found.xcodeproj' -scheme 'Lost&Found' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'Lost&Found.xcodeproj' -scheme 'Lost&Found' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

两套联调脚本创建并清理临时数据、使用 loopback 和假驱动。不要改成正式 data 目录或真实 gpio 模式。运行日志会写到本机 `verification/`，不会因文档提交自动加入 Git。

## 4. 演示与后续验收

| 项目 | 当前状态／下一步 |
| --- | --- |
| 01／02 锁扣状态 | 用户已确认变化；演示时检查 Door not closed → Door closed，关门不能自动完成库存操作 |
| 存入闭环 | 用真实物品走拍照、识别、分配、指定格开门、关门、手动完成；完成前不应进入可领取搜索 |
| 领取闭环 | 语音或键入找到候选，选中并打开所属格，取出关门后确认，物品消失且格口释放 |
| 中断续办 | 待确认时离开／重启，再点击首页 I found something；应进入原格确认，无新开锁命令 |
| 后台开门 | 一次 Open，无原因表单或二次确认；命令完成不应改变物品存取状态 |
| 震动报警 | 固定传感器后轻敲验证阈值；Dismiss 只收起弹窗，Clear alert 确认该条报警；调灵敏度避免误报 |
| 03／04 与供电 | 若用于完整四格展示，逐格验证实际释放、复扣、布线与独立供电；目前仍人工确认 |
| 设备与恢复 | 相机/麦克风允许和拒绝、Guided Access、网络中断、整机重启、未知请求工作人员处置分别记录 |
| 可访问性 | 继续检查竖屏、全量 Dynamic Type、VoiceOver 和实际 iOS 17 运行；当前主要运行验证为 iOS 26.3 系列 |

## 5. 当前限制

- 管理台有密码会话，兼容访客 API 尚无统一身份鉴权；站点继续按可信局域网课堂项目使用。
- 两路锁扣反馈不是物品在位或身份识别。断线与开门均可能读 HIGH，传感器异常需要现场检查。
- 03／04 无反馈；软件脉冲保护和传感器测试不能证明全部继电器、电源及机械安装行为。
- 未完成照片草稿仍仅驻留当前进程；隔间请求 ID 已持久化，两者恢复能力不同。
- AI 匹配依赖标签和备注，候选库最多 200 条，未做所有权证明或大规模检索评估。
- 后台可查看冷却剩余时间；iPad 首页空格数量按 `free` 计算，全部空格仍冷却时由服务端返回 429。
- 尚无自动照片保留期限；真实物品的完整四格存取、掉电恢复和长期运行仍需独立现场记录。

## 6. 修订记录

2026-10-22 初稿记录初始四格版本的 99 项 Python、42 项 Swift Core、12／10 项 HTTP 检查。当日后续加入管理台、震动、两路反馈与入口恢复，现汇总至功能提交 `e722f21`；旧的“无反馈”“没有管理员鉴权”“四格尚未部署”不再代表当前实现。历史验证条目按原时间保留。
