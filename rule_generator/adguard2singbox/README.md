# AdGuard to Sing-Box

将 AdGuard 规则转换为 Sing-Box 使用的 `.srs` 规则集。生成好的文件在 `proxy_filter/sing-box` 中，由 GitHub Actions 定期更新。

## 数据来源

1. https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
2. https://anti-ad.net/adguard.txt

## 手动运行

如果需要在本地转换，可参考工作流步骤：下载最新的 sing-box 二进制，并执行 `sing-box rule-set convert <源文件> --output <目标.srs> --type adguard`。
