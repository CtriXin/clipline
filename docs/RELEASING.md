# 发布流程

1. 改 `scripts/build-app.sh` 里的 `VERSION`。
2. `scripts/make-dmg.sh`：构建通用二进制 → Developer ID 签名 → 打 dmg → 公证 → staple。
   - 签名身份：钥匙串里的 `Developer ID Application: xin song (2HJP9YYL3H)`（脚本自动发现）。
   - 公证凭据：钥匙串 profile `clipline-notary`（App Store Connect API Key `ZV48LXKS84`，2026-10-10 存入）。
3. 校验：`spctl --assess --type open --context context:primary-signature -v build/Clipline-X.Y.Z.dmg` 应为 `Notarized Developer ID`。
4. `gh release create vX.Y.Z build/Clipline-X.Y.Z.dmg -R CtriXin/clipline`，说明里附 SHA-256。

## 踩过的坑

- **403 A required agreement is missing or has expired**：Apple 协议更新后要 Account Holder 在 developer.apple.com / App Store Connect「商务 → 协议」重新同意；同意后 API 侧要几分钟才生效，期间 `store-credentials` 和 `notarytool info` 会间歇 403。上传成功但轮询 403 时，用 `xcrun notarytool info <submission id> --keychain-profile clipline-notary` 再查即可。
- 本机 Gatekeeper 是关着的（`spctl` 显示 `override=security disabled`），首次打开体验要在同事机器上确认。
- 仓库里的 `v1.0.0` tag 来自上游，与 Clipline 版本无关。
