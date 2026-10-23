# 领域文档

说明各工程 skill 在探索代码库时应如何使用本仓库的领域文档。

## 探索之前先读这些

- 仓库根目录的 **`GLOSSARY.md`**，或者
- 如果仓库根目录存在 **`GLOSSARY-MAP.md`**：它指向每个 context 各自的 `GLOSSARY.md`，阅读与当前主题相关的那些。
- **`docs/adr/`**：阅读与你即将修改的区域相关的 ADR。在 multi-context 仓库中，还要查看 `src/<context>/docs/adr/` 中针对特定 context 的决策。

如果这些文件不存在，**直接跳过，不作提示**。不要指出它们缺失，也不要建议预先创建。`/domain-modeling` skill（可通过 `/grill-with-docs` 和 `/improve-codebase-architecture` 进入）会在术语或决策真正确定时按需创建它们。

## 文件结构

Single-context 仓库（大多数仓库）：

```
/
├── GLOSSARY.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

Multi-context 仓库（根目录存在 `GLOSSARY-MAP.md`）：

```
/
├── GLOSSARY-MAP.md
├── docs/adr/                          ← 系统级决策
└── src/
    ├── ordering/
    │   ├── GLOSSARY.md
    │   └── docs/adr/                  ← context 级决策
    └── billing/
        ├── GLOSSARY.md
        └── docs/adr/
```

## 使用 glossary 中的术语

当你的输出提到某个领域概念时（issue 标题、重构提案、假设、测试名称等），使用 `GLOSSARY.md` 中定义的术语。不要换用 glossary 明确避免的同义词。

如果所需的概念还不在 glossary 中，这本身就是一个信号：要么你在发明项目并不使用的说法（请重新考虑），要么确实存在空缺（记下来交给 `/domain-modeling`）。

## 明确指出与 ADR 的冲突

如果你的输出与现有 ADR 相矛盾，要明确指出，而不是悄悄推翻：

> _与 ADR-0007（event-sourced orders）相矛盾，但值得重新讨论，因为……_
