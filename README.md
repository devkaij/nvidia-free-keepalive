# nvidia-free 创空间保活(GitHub Actions 侧)

魔搭创空间免费实例是**请求闲置型休眠**(官方口径:重新访问即激活启动),本仓库用
GitHub Actions 每 10 分钟做实例健康检查 + 状态查询,作为**双重保障的第二路**。

**保活对象**:创空间 `A177593/nvidia-free-proxy`(NVIDIA 免费代理云端版,Docker 类型)。

## 今天(2026-10-18)实测的域名可达性(workflow 依据)

| 目标 | 国内(本机) | 新加坡(LXD 节点) | 美国(GH Actions) |
|---|---|---|---|
| `studio-*.api-inference.modelscope.net`(实例) | ✅ 200 | ❌ WAF 超时 | 本 workflow 实时测 |
| `*.ms.show`(旧独立域名) | ❌ 403「请用 API 专用地址」 | ❌ 000 | 大概率同样 403 |
| `www.modelscope.cn/studios/...`(页面) | ✅(前端 HTML,**非实例**) | ✅(同上) | ✅(同上) |
| `www.modelscope.cn/api/v1/studio/...`(状态) | ✅ | ✅ | ✅ |

结论性事实:

1. **ms.show 匿名心跳路已断**——平台全球 403 引导去 api-inference(2026-10 策略,
   与 9 月社区的 ms.show 方案不同了);但 `www.modelscope.cn/studios/...` 页面 ping
   只是前端 HTML,**未经平台确认计入实例访问**,证据等级低,不做主判据。
2. **api-inference 是唯一实例级目标,但要账号 token**(`Authorization: Bearer`)。
   国内 IP 实测 200。GH 出口能否打通由 workflow 第 ① 步实时判定(通=真实例 ping)。
3. **HTTP 200 不是有效判据**(SPA 恒 200),权威判据是平台接口的 `Data.Status`。

## workflow 行为

`keepalive.yml`(每 10 分钟):

| 步骤 | 作用 | 失败语义 |
|---|---|---|
| ① api-inference 健康检查 | 真实例 ping(需 secret `MODELSCOPE_TOKEN`) | `::warning::` 不阻断(GH 出口可能不通) |
| ② 查 `Data.Status` | 权威状态判据 | `::error::` 失败并通知;非 Running 只 warning |

`keep-repo-active.yml`(每月 1 号):提交 `heartbeat.txt` 制造仓库活动——GitHub 会在
60 天无活动时**自动禁用** scheduled workflow(`disabled_inactivity`,不自动恢复,
前车之鉴跑了 744 次被禁)。**此文件与 heartbeat.txt 勿删。**

## 配置 secret(可选但建议)

仓库 Settings → Secrets → Actions → New repository secret:

- `MODELSCOPE_TOKEN` = 魔搭 Access Token(`ms-` 开头)。不配则 ① 跳过,只剩 ② 哨点。

## 三角分工(第二路只是备份)

| 路 | 载体 | 能力 | 定位 |
|---|---|---|---|
| 主路 | 本机 DSH 定时任务(国内,电脑开机) | api-inference 真实例 ping | 保活主力(关机即停) |
| 本路 | GitHub Actions(美国) | api-inference 试探 + Status 判据 | 补关机时段,境外哨点 |
| 三路 | 自有 SG LXD 节点(新加坡) | Status 判据( `/var/log/nvidia-keepalive.log`) | 独立哨点,发现「睡」的形态 |

现实预期:半夜若三路都够不着实例(ms.show 已断),空间仍可能睡;**首次请求触发冷启动
唤醒(1~3 分钟,代理侧预算默认 3 分钟)**——「电脑关机也能用」依然成立,只是久置后
第一次调用需要等唤醒。要更准的外部心跳可自行注册 cron-job.org/UptimeRobot
(探针节点多,30s 超时对冷启动「请求已到达即唤醒」)。

## 手动检查

```bash
gh api /repos/<owner>/nvidia-free-keepalive/actions/workflows --jq '.workflows[] | .name + "=" + .state'
gh run list -R <owner>/nvidia-free-keepalive -L 10
curl -s -A 'Mozilla/5.0' "https://www.modelscope.cn/api/v1/studio/A177593/nvidia-free-proxy" | grep -o '"Status":"[^"]*"'
```
