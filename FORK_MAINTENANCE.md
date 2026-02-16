# OpenClaw Fork 維護指南

本 fork 包含一個針對 Chrome Extension Relay 的修復，修改了 `src/browser/pw-session.ts` 中的 `findPageByTargetId` 函數。

## 修復內容

**問題**: 使用 `profile="chrome"` (Extension Relay) 時，`browser tabs` 成功但 `browser snapshot` 報 "tab not found"。

**原因**: `findPageByTargetId` 先嘗試 Playwright CDP 取得 targetId，但 Extension Relay 阻止了 `Target.attachToBrowserTarget`，導致找不到頁面。

**修復**: 調整 `findPageByTargetId` 的優先順序，先用 `/json/list` endpoint 匹配 targetId，再 fallback 到 Playwright CDP。

## Remote 設定

```
origin   → https://github.com/audichuang/openclaw.git  (你的 fork)
upstream → https://github.com/openclaw/openclaw.git     (官方)
```

## 當前配置

- **分支策略**: `fix/extension-relay-targetid` 基於最新 release tag
- **穩定性**: 基於 release tag 而非 main，避免編譯失敗的 commit
- **Cron 頻率**: 每 6 小時執行一次檢查

## 更新策略

- **基於 release tag**（如 `v2026.2.15`），不是 main 分支
- fix 分支的 commit 永遠 rebase 在最新 release tag 之上
- 這避免了 main 上可能存在的編譯失敗的 commit

## 快取機制

`--check` 模式使用 git worktree 在 `/tmp` 試編譯，完全不影響正在運行的 Gateway。

| 目錄                                      | 說明                                         |
| ----------------------------------------- | -------------------------------------------- |
| `/tmp/openclaw-trial/v{版本}/.trial-ok`   | 驗證成功，下次 cron 跳過重試                 |
| `/tmp/openclaw-trial/v{版本}/.trial-fail` | 驗證失敗（包含失敗原因），下次 cron 直接報錯 |
| 新 tag 出現                               | 自動清除舊 tag 的快取目錄                    |

## 自動更新檢查（Cron）

每 6 小時 cron job 執行 `scripts/fork-update.sh --check`：

- 只檢查有沒有新 release tag，**不會自動更新**
- 有新版 → 通知你手動執行更新
- 沒新版 → 靜默（或顯示「已是最新版本」）

## 手動更新

### 一鍵更新（推薦）

```bash
~/github/openclaw/scripts/fork-update.sh
```

腳本會自動：

1. `git fetch upstream --tags`
2. 比較當前 base tag 和最新 release tag
3. `git rebase --onto <new-tag> <old-tag> fix/extension-relay-targetid`
4. `pnpm install` → `pnpm build` → `pnpm ui:build`（含 Control UI）
5. 如果 build 或 ui:build 失敗 → **自動還原 dist/**，gateway 不受影響
6. 如果 rebase 衝突 → **自動 abort rebase**，還原到更新前狀態
7. 全部成功 → `openclaw gateway restart` + push 到 fork

### 只檢查不更新

```bash
~/github/openclaw/scripts/fork-update.sh --check
```

此命令會：

- 在 `/tmp/openclaw-trial/<tag>` 建立 git worktree 進行試編譯
- 驗證 rebase → `pnpm install` → `pnpm build` → `pnpm ui:build` 全流程
- worktree 的 build 輸出在自己的 `dist/` 下，**不影響主 repo 的 dist/**
- 結果寫入快取目錄（`.trial-ok` / `.trial-fail`），供下次 cron 參考
- **不修改 repo 本體**，Gateway 完全不受影響

## 更新失敗處理

| 失敗類型          | 腳本行為                         | 你該怎麼做                               |
| ----------------- | -------------------------------- | ---------------------------------------- |
| rebase 衝突       | 自動 abort + reset，報告衝突檔案 | 手動解決衝突，見下方「手動處理衝突」章節 |
| pnpm install 失敗 | 停止，dist/ 已還原               | 檢查網路或 lockfile，解決後再跑一次      |
| pnpm build 失敗   | 停止，dist/ 已還原               | 根據錯誤訊息排查，可能需要手動調整代碼   |
| ui:build 失敗     | 停止，dist/ 已還原               | 通常是 UI 依賴問題，嘗試 `pnpm install` 後重跑 |

## 手動處理衝突

如果 `fork-update.sh` 報告 rebase 衝突（腳本會自動還原），手動操作：

```bash
cd ~/github/openclaw
git fetch upstream --tags

# 找到最新 release tag
git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1

# 手動 rebase（替換 TAG 為實際值）
git checkout fix/extension-relay-targetid
git rebase --onto <NEW_TAG> <OLD_TAG> fix/extension-relay-targetid

# 解決衝突（主要是 src/browser/pw-session.ts 的 findPageByTargetId 函數）
# 確保：
#   1. /json/list 的匹配邏輯在 CDP session 之前
#   2. 匹配策略順序：精確 id → URL → title → index
#   3. CDP session 作為 fallback
git add src/browser/pw-session.ts
git rebase --continue

# 編譯 + 重啟
pnpm install && pnpm run build && CI=true pnpm run ui:build
openclaw gateway restart

# 推送
git push origin fix/extension-relay-targetid --force-with-lease
```

## 手動回滾（如果更新後有問題）

```bash
cd ~/github/openclaw

# 1. 查看 fix 分支的歷史，找到更新前的 commit
git log --oneline fix/extension-relay-targetid -10

# 2. 強制回滾到指定 commit（假設是 abc1234）
git checkout fix/extension-relay-targetid
git reset --hard abc1234

# 3. 重新編譯
pnpm run build && CI=true pnpm run ui:build

# 4. 重啟 gateway
openclaw gateway restart

# 5. 推送（如果需要）
git push origin fix/extension-relay-targetid --force-with-lease
```

## 驗證修復是否生效

```bash
openclaw browser status --profile chrome   # 確認 profile 存在
openclaw browser tabs --profile chrome     # 列出分頁
openclaw browser snapshot --profile chrome # 這個之前會失敗，修復後應成功
```
