#!/usr/bin/env bash
# fork-update.sh — Custom update script for audichuang/openclaw fork
#
# Usage:
#   ~/github/openclaw/scripts/fork-update.sh          # apply update
#   ~/github/openclaw/scripts/fork-update.sh --check   # dry-run: check + trial build in tmp worktree
#
# Strategy:
#   - Based on RELEASE TAGS (not main), so we always sit on stable releases.
#   - --check: trial rebase + build in a git worktree (zero impact on running gateway).
#   - No flag:  apply rebase + build in-place, stash dist/ for rollback on failure.

set -uo pipefail

REPO_DIR="$HOME/github/openclaw"
FIX_BRANCH="fix/extension-relay-targetid"
UPSTREAM_REMOTE="upstream"

cd "$REPO_DIR"

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
fi

# --- Helper: find latest stable release tag (vYYYY.M.D, no -beta) ---
find_latest_release_tag() {
  git tag -l 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

# --- Helper: find current base tag of fix branch ---
find_current_base_tag() {
  git describe --tags --abbrev=0 "$FIX_BRANCH~1" 2>/dev/null || echo "unknown"
}

# --- 1. Fetch upstream tags ---
echo "==> Fetching upstream tags..."
git fetch "$UPSTREAM_REMOTE" --tags --quiet

# --- 2. Compare release tags ---
CURRENT_BASE_TAG=$(find_current_base_tag)
LATEST_TAG=$(find_latest_release_tag)
CURRENT_VERSION=$(node -p "require('./package.json').version" 2>/dev/null || echo "unknown")

if [[ -z "$LATEST_TAG" ]]; then
  echo "✗ 找不到任何 release tag"
  exit 1
fi

if [[ "$CURRENT_BASE_TAG" == "$LATEST_TAG" ]]; then
  echo "✓ 已是最新 release ($LATEST_TAG, 本地版本 v$CURRENT_VERSION)"
  exit 0
fi

echo "⚡ 發現新 release"
echo "   目前基於: $CURRENT_BASE_TAG (v$CURRENT_VERSION)"
echo "   最新版本: $LATEST_TAG"

# ============================================================
# --check mode: trial rebase + build in a named worktree
# Directory named by release tag → already-checked tags are skipped.
# Nothing in REPO_DIR is modified. Gateway is unaffected.
# ============================================================
if [[ "$CHECK_ONLY" == "true" ]]; then
  # Worktree named after the release tag for caching
  TRIAL_BASE="/tmp/openclaw-trial"
  TRIAL_DIR="$TRIAL_BASE/$LATEST_TAG"

  # If a successful trial already exists for this tag, skip
  if [[ -f "$TRIAL_DIR/.trial-ok" ]]; then
    echo ""
    echo "✓ $LATEST_TAG 已驗證過可正常編譯 (快取: $TRIAL_DIR)"
    echo "  請執行以下命令套用更新:"
    echo "    ~/github/openclaw/scripts/fork-update.sh"
    exit 0
  fi

  # If a failed trial exists for this tag, report cached failure
  if [[ -f "$TRIAL_DIR/.trial-fail" ]]; then
    FAIL_REASON=$(cat "$TRIAL_DIR/.trial-fail")
    echo ""
    echo "✗ $LATEST_TAG 上次驗證失敗 (快取: $TRIAL_DIR)"
    echo "  原因: $FAIL_REASON"
    echo ""
    echo "  若要重新驗證，先刪除快取: rm -rf $TRIAL_DIR"
    echo "  參考: ~/github/openclaw/FORK_MAINTENANCE.md"
    exit 1
  fi

  # Clean up old trial dirs for previous tags
  if [[ -d "$TRIAL_BASE" ]]; then
    for old_dir in "$TRIAL_BASE"/v*; do
      [[ -d "$old_dir" ]] && [[ "$old_dir" != "$TRIAL_DIR" ]] && {
        git worktree remove --force "$old_dir" 2>/dev/null || true
        rm -rf "$old_dir"
      }
    done
    git worktree prune 2>/dev/null || true
  fi

  echo ""
  echo "==> [試編譯] 建立 worktree: $TRIAL_DIR ..."
  mkdir -p "$TRIAL_BASE"

  git worktree add --detach "$TRIAL_DIR" "$FIX_BRANCH" --quiet 2>/dev/null
  if [[ $? -ne 0 ]]; then
    rm -rf "$TRIAL_DIR"
    echo "✗ 無法建立 worktree，請手動檢查"
    exit 1
  fi

  cleanup_trial() {
    git worktree remove --force "$TRIAL_DIR" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    rm -rf "$TRIAL_DIR"
  }

  mark_fail() {
    # Keep the dir but mark it as failed, so next cron run skips rebuild
    (cd "$TRIAL_DIR" && git rebase --abort 2>/dev/null || true)
    git worktree remove --force "$TRIAL_DIR" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    # Recreate as plain dir with just the fail marker
    rm -rf "$TRIAL_DIR"
    mkdir -p "$TRIAL_DIR"
    echo "$1" > "$TRIAL_DIR/.trial-fail"
  }

  # Trial rebase
  echo "==> [試編譯] Rebase onto $LATEST_TAG..."
  REBASE_OUTPUT=$(cd "$TRIAL_DIR" && git rebase --onto "$LATEST_TAG" "$CURRENT_BASE_TAG" HEAD 2>&1)
  if [[ $? -ne 0 ]]; then
    CONFLICT_FILES=$(cd "$TRIAL_DIR" && git diff --name-only --diff-filter=U 2>/dev/null || true)
    FAIL_MSG="rebase 衝突 onto $LATEST_TAG"
    [[ -n "$CONFLICT_FILES" ]] && FAIL_MSG="$FAIL_MSG (檔案: $CONFLICT_FILES)"
    mark_fail "$FAIL_MSG"
    echo ""
    echo "✗ Rebase 衝突！無法自動更新到 $LATEST_TAG"
    if [[ -n "$CONFLICT_FILES" ]]; then
      echo "  衝突檔案:"
      echo "$CONFLICT_FILES" | sed 's/^/    /'
    fi
    echo ""
    echo "請手動解決衝突，參考: ~/github/openclaw/FORK_MAINTENANCE.md"
    exit 1
  fi

  # Trial install
  echo "==> [試編譯] pnpm install..."
  INSTALL_OUTPUT=$(cd "$TRIAL_DIR" && pnpm install --frozen-lockfile 2>&1 || cd "$TRIAL_DIR" && pnpm install 2>&1)
  if [[ $? -ne 0 ]]; then
    mark_fail "pnpm install 失敗"
    echo ""
    echo "✗ pnpm install 失敗！$LATEST_TAG 的依賴安裝有問題"
    echo "  請手動檢查，參考: ~/github/openclaw/FORK_MAINTENANCE.md"
    exit 1
  fi

  # Trial build
  echo "==> [試編譯] pnpm build..."
  TRIAL_BUILD_OUTPUT=$(cd "$TRIAL_DIR" && pnpm run build 2>&1)
  TRIAL_BUILD_EXIT=$?

  if [[ $TRIAL_BUILD_EXIT -eq 0 ]]; then
    echo "==> [試編譯] pnpm ui:build..."
    TRIAL_UI_OUTPUT=$(cd "$TRIAL_DIR" && CI=true pnpm run ui:build 2>&1)
    if [[ $? -ne 0 ]]; then
      UI_TAIL=$(echo "$TRIAL_UI_OUTPUT" | tail -20)
      mark_fail "ui:build 失敗"
      echo ""
      echo "✗ UI 編譯失敗！$LATEST_TAG 的 Control UI 無法編譯"
      echo ""
      echo "  錯誤 (最後 20 行):"
      echo "$UI_TAIL" | sed 's/^/    /'
      echo ""
      echo "  參考: ~/github/openclaw/FORK_MAINTENANCE.md"
      exit 1
    fi
  fi

  if [[ $TRIAL_BUILD_EXIT -ne 0 ]]; then
    BUILD_TAIL=$(echo "$TRIAL_BUILD_OUTPUT" | tail -20)
    mark_fail "pnpm build 失敗"
    echo ""
    echo "✗ 編譯失敗！$LATEST_TAG 加上我們的修改後無法編譯"
    echo ""
    echo "  編譯錯誤 (最後 20 行):"
    echo "$BUILD_TAIL" | sed 's/^/    /'
    echo ""
    echo "  請檢查 $LATEST_TAG 的 changelog 和修改："
    echo "    git log $CURRENT_BASE_TAG..$LATEST_TAG --oneline -- src/browser/"
    echo "  參考: ~/github/openclaw/FORK_MAINTENANCE.md"
    exit 1
  fi

  # Success — clean up worktree but keep dir with ok marker
  cleanup_trial
  mkdir -p "$TRIAL_DIR"
  echo "$(date -Iseconds)" > "$TRIAL_DIR/.trial-ok"

  echo ""
  echo "✓ 新版本 $LATEST_TAG 可正常拉取並編譯！"
  echo "  驗證結果已快取: $TRIAL_DIR"
  echo "  請執行以下命令套用更新:"
  echo "    ~/github/openclaw/scripts/fork-update.sh"
  exit 0
fi

# ============================================================
# Apply mode: actually update the working tree
# ============================================================

# --- 3. Pre-flight checks ---
ORIGINAL_BRANCH=$(git branch --show-current)
ORIGINAL_SHA=$(git rev-parse HEAD)

if [[ -n $(git status --porcelain) ]]; then
  echo "✗ 工作目錄有未提交的修改，請先處理"
  git status --short
  exit 1
fi

# --- 4. Stash dist/ aside for safe rollback ---
DIST_STASH="$REPO_DIR/.dist-rollback"
rm -rf "$DIST_STASH"
if [[ -d "$REPO_DIR/dist" ]]; then
  echo "==> 暫存 dist/ → .dist-rollback ..."
  mv "$REPO_DIR/dist" "$DIST_STASH"
fi

# --- Rollback function ---
rollback() {
  local reason="$1"
  echo ""
  echo "✗ 更新失敗: $reason"
  echo "==> 還原到更新前狀態..."

  # Abort any in-progress rebase
  git rebase --abort 2>/dev/null || true

  # Restore original branch position
  git checkout "$FIX_BRANCH" --quiet 2>/dev/null || true
  git reset --hard "$ORIGINAL_SHA" --quiet 2>/dev/null || true

  # Restore dist/ — mv back, gateway immediately works again
  if [[ -d "$DIST_STASH" ]]; then
    rm -rf "$REPO_DIR/dist"
    mv "$DIST_STASH" "$REPO_DIR/dist"
    echo "==> dist/ 已還原，gateway 不受影響"
  fi

  echo ""
  echo "請手動檢查問題後重試，或參考: ~/github/openclaw/FORK_MAINTENANCE.md"
  exit 1
}

# --- 5. Rebase fix branch onto new release tag ---
echo "==> Rebase $FIX_BRANCH onto $LATEST_TAG..."
git checkout "$FIX_BRANCH" --quiet

git rebase --onto "$LATEST_TAG" "$CURRENT_BASE_TAG" "$FIX_BRANCH"
if [[ $? -ne 0 ]]; then
  echo ""
  echo "  衝突檔案:"
  git diff --name-only --diff-filter=U 2>/dev/null || true
  rollback "rebase 衝突 ($FIX_BRANCH onto $LATEST_TAG)。需要手動解決衝突"
fi

# --- 6. Install deps ---
echo "==> 安裝依賴..."
pnpm install --frozen-lockfile 2>/dev/null || pnpm install
if [[ $? -ne 0 ]]; then
  rollback "pnpm install 失敗"
fi

# --- 7. Build into fresh dist/ (old one is stashed) ---
echo "==> 編譯到新 dist/ ..."
pnpm run build
if [[ $? -ne 0 ]]; then
  rollback "pnpm build 失敗"
fi

echo "==> 編譯 Control UI..."
CI=true pnpm run ui:build
if [[ $? -ne 0 ]]; then
  rollback "ui:build 失敗"
fi

# Build succeeded — new dist/ is ready, remove stashed old one
rm -rf "$DIST_STASH"
# Clean up trial cache for this tag (no longer needed)
rm -rf "/tmp/openclaw-trial/$LATEST_TAG" 2>/dev/null || true
echo "==> 編譯成功，舊 dist/ 已清除"

# --- 8. Restart gateway ---
echo "==> 重啟 gateway..."
openclaw gateway restart
if [[ $? -ne 0 ]]; then
  echo "⚠ gateway restart 失敗，請手動重啟: openclaw gateway restart"
  echo "  (build 已成功，dist/ 是新版本)"
fi

# --- 9. Push updated branch ---
echo "==> 推送到 fork..."
git push origin "$FIX_BRANCH" --force-with-lease 2>/dev/null || echo "⚠ push 失敗，請手動: git push origin $FIX_BRANCH --force-with-lease"

# --- 10. Report ---
NEW_VERSION=$(node -p "require('./package.json').version" 2>/dev/null || echo "unknown")
echo ""
echo "✓ 更新完成！"
echo "  版本: v$CURRENT_VERSION → v$NEW_VERSION"
echo "  基於: $CURRENT_BASE_TAG → $LATEST_TAG"
echo "  分支: $FIX_BRANCH"
