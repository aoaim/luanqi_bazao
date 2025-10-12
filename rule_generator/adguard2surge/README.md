# AdGuard to Surge

将 AdGuard 去广告规则转换为 Surge Domain List 格式，输出保存到仓库根目录下的 `proxy_filter/surge`。

## 使用

```bash
npm install
npm run gen-domain-set
```

生成的规则包括 Tracking Protection、Chinese、Base 和 DNS 四类，对应的源地址与原项目保持一致。
