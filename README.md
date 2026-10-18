# nvidia-free 创空间保活(GitHub Actions 侧)

魔搭创空间免费实例是**请求闲置型休眠**(官方口径:重新访问即激活启动),本仓库用
GitHub Actions 每 10 分钟 ping + 查状态,防「无人访问 → 休眠」。

**保活对象**:创空间 `A177593/nvidia-free-proxy`(NVIDIA 免费代理云端版,
Docker 类型,API 入口 `studio-a177593-nvidia-free-proxy.api-inference.modelscope.net`)。

> 这是**双重保障的第二保障**:第一保障是跑在自有 SG LXD 节点的同款 cron
> (`/opt/nvidia-keepalive/keepalive.sh`,每 10 分钟)。两路独立,任一挂另一路仍在。

## 判据(为什么不能只看 HTTP 200)

站点 SPA 对不存在的地址也返回 200,**HTTP 200 不是有效判据**。有效判据是
平台接口的 `Data.Status`:

```bash
curl -s -A 'Mozilla/5.0' "https://www.modelscope.cn/api/v1/studio/A177593/nvidia-free-proxy" \
  | grep -o '"Status":"[^"]*"'
```

`keepalive.yml` 每 10 分钟做三件事:

| 步骤 | 作用 | 失败语义 |
|---|---|---|
| Ping Studio 页面 | 产生实例访问,防休眠 | ::error:: 步骤失败(会通知) |
| 查 Data.Status | 确认真实状态(非 Running 只 warning,ping 本身即唤醒) | ::error:: 仅查询本身失败 |
| (可选)api-inference 健康检查 | 验证 API 域名 | ::warning:: 不阻断(该域名对部分境外 IP 被 WAF 挡) |

## 为什么有第二个 workflow

GitHub 会在仓库 **60 天无任何活动**时自动禁用 scheduled workflow
(`disabled_inactivity`,不自动恢复)。`keep-repo-active.yml` 每月 1 号提交
`heartbeat.txt` 制造活动,让计时器归零。**此文件勿删。**

## 已知限制

- GitHub cron 是尽力而为:高峰期实测延迟 5~15 分钟,偶尔丢跑。要更精准换外部监控
  (cron-job.org / UptimeRobot 5 分钟粒度)——但本仓库是第二保障,够了。
- ping 只能防「请求闲置」型休眠;平台硬性时长上限 ping 救不了(以创空间控制台为准)。

## 手动检查

```bash
# workflow 是否 active(出现 disabled_inactivity 就是被 60 天规则杀了)
gh api /repos/<owner>/nvidia-free-keepalive/actions/workflows --jq '.workflows[] | .name + "=" + .state'
# 最近运行
gh run list -R <owner>/nvidia-free-keepalive -L 10
# 空间此刻状态
curl -s -A 'Mozilla/5.0' "https://www.modelscope.cn/api/v1/studio/A177593/nvidia-free-proxy" | grep -o '"Status":"[^"]*"'
```
