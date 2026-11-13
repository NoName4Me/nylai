# 提交规范

- 提交信息必须使用 Conventional Commits：`type(scope)!: 描述`，scope 和 `!` 可省略。
- type 仅限 `feat`、`fix`、`docs`、`style`、`refactor`、`perf`、`test`、`build`、`ci`、`chore`、`revert`；描述可用中文。
- 首次提交前运行 `sh scripts/install-git-hooks.sh` 安装本地校验；不得用 `--no-verify` 绕过校验。
- 校验失败时修正提交信息后再提交。
