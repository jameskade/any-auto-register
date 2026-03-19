# Fork Sync Rules

## 仓库关系

- 本仓库按 fork 工作流维护。
- 父仓库（upstream）固定为：`git@github.com:lxf746/any-auto-register.git`
- 本文件故意不记录任何个人 fork 地址、用户名、邮箱或其他个人信息。

## “同步远程仓库”的默认含义

- 当用户说“同步远程仓库”“同步父仓库”“拉最新代码”时，默认理解为：
  1. 从 `upstream` 拉取最新代码
  2. 将 `upstream/main` 同步到本地 `main`
- 不要把这类请求默认理解成推送代码。

## 远程仓库规则

- `origin` 视为用户自己的 fork。
- `upstream` 视为父仓库。
- 禁止向 `upstream` 推送。
- 只有用户明确要求更新自己的 fork 时，才允许推送 `origin`。

## 新机器初始化

- 新机器 clone 后，如果本地没有 `upstream`，应先添加：

```bash
git remote add upstream git@github.com:lxf746/any-auto-register.git
```

## 推荐同步顺序

- 先检查是否有未提交改动。
- 若工作区不干净，优先让本地改动安全落地（stash 或本地提交）。
- 然后执行：

```bash
git fetch upstream
git checkout main
git merge upstream/main
```

- 如有冲突，先解决冲突，再继续后续步骤。
- 只有用户明确要求时，才执行：

```bash
git push origin main
```
