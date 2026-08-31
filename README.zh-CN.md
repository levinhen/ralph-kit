# ralph-kit

[English](./README.md) | 简体中文

一条命令即可把 [Ralph](https://github.com/snarktank/ralph) 自主 agent 循环装进任意项目，并附带配套的 Claude Code 技能（`/prd`、`/ralph`）和 Codex / pi（`AGENTS.md`）集成。

一段话概括整个玩法：**你在对话里描述一个需求 → 生成一份由你审阅确认的 PRD → PRD 被拆成一组小而可验证的用户故事 → 一个 shell 循环在隔离的 git worktree 里为每个故事启动一个全新的 AI agent，逐个实现、检查、提交，直到所有故事通过 → 分支合并回基线分支，本次运行的设计决策被沉淀进长期维护的 design ledger，运行目录归档。** 文件就是记忆，git 就是检查点，每次 agent 调用都从干净的上下文窗口开始。

安装后会在项目里放入：

```
.claude/skills/prd/SKILL.md   # /prd 斜杠命令
.claude/skills/ralph/SKILL.md # /ralph 斜杠命令
ralph/
  scripts/                    # 静态循环代码（ralph.sh、orchestrate.sh、lib/、agent 提示词）
  tasks/                      # 进行中的 run 的 PRD markdown（首次使用时创建；安装器永不触碰）
  runs/                       # 进行中的运行（运行时创建，不随包分发）
  archive/                    # 已完成并沉淀的运行 + 其源 PRD markdown（运行时创建）
  locks/                      # 运行时锁目录（运行时创建）
AGENTS.md                     # （创建或追加标记段；已有内容保留）
```

Ralph 生成的一切都收在 `ralph/` 下——代码、运行时状态、归档放在一起，不污染 `scripts/`。

**环境要求：** Bash（macOS、Linux，或 Windows 上的 Git Bash）、`git`、`jq`、Node.js 18+，以及 `PATH` 上至少一个 agent CLI——`claude`（Claude Code）、`codex` 或 `pi`（[pi-coding-agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)）。

## 整体实现流程

### 流水线总览

```
/prd 技能（对话：盘点在飞的 PRD → 澄清需求 → 用业务语言复述并确认）
        │
        ▼
ralph/tasks/prd-<feature>.md          人类可读的 PRD
        │
        │  /ralph 技能（盘点在飞的 run → 校验方案 → 拆成
        │  单个上下文窗口能完成的故事）
        ▼
ralph/runs/<run_id>/prd.json          机器可读的运行定义
  + state.json + progress/            （故事、userNeed、分支名）
        │
        │  ralph/scripts/ralph.sh --run <run_id>
        ▼
.worktrees/<run_id>（隔离的 git worktree，检出分支 ralph/<feature>）
        │
        │  轮次循环——每个故事一个全新 agent：
        │    1. 取第一个 passes=false 的故事
        │    2. prompt = agent 手册 + 故事 JSON + 记忆切片
        │    3. 启动全新的 claude / codex / pi 进程
        │    4. agent：实现 → 质量检查 → passes=true → 提交
        │    5. 把故事状态同步回 prd.json
        │       passes!=true → 疏通轮：真被阻塞？ → 重构 PRD → 循环继续
        │                            没被阻塞？   → 做完故事 → 循环继续
        │                            都不是？     → 输出终端 → 停止
        ▼
所有故事 passes=true
        │
        ▼
merge-back 回合      git merge --no-ff 合回基线分支
                     （冲突 → 专门的 agent 回合解决）
        │
        ▼
consolidation 回合   沉淀运行学到的设计 → docs/design-ledger/
        │
        ▼
归档                 ralph/runs/<id> + ralph/tasks/prd-<id>.md
                     → ralph/archive/<date>-<id>
```

### 阶段 1 —— 规划：`/prd` 产出人类可读的 PRD

在 Claude Code 对话中运行 `/prd` 并描述需求。该技能会：

1. **先盘点已经写好但还没跑完的 PRD**，不用你提醒，在问你任何问题之前就把结果报出来；
2. 提出澄清问题（字母选项格式，阻塞性问题优先）；
3. 持续追问，直到关键歧义全部消除；
4. 用纯业务语言复述需求，等你确认；
5. 写出 `ralph/tasks/prd-<feature>.md`——目标、带可验证验收标准的用户故事、功能需求、非目标、待定问题。

它刻意**不做任何实现**。PRD 是供人审阅的契约。

**关于这次盘点。** 跑完并沉淀的 run 连同它的源 PRD 会被移进 `ralph/archive/`，所以还留在 `ralph/tasks/` 或 `ralph/runs/` 里的，按定义就是"写好了但没跑完"——不需要额外记账，目录本身就是状态。技能会读这两个目录，把找到的东西和各自跑到哪儿（`2/5 stories passing`）报给你，因为一份 PRD 跑到什么程度，直接决定了改动它的设计要付多大代价。已经设计过的东西不会被重新设计一遍：重叠的部分写进新 PRD 的**非目标**，并点名由哪份 PRD 负责。你也不会被早先的决定锁死——新 PRD 可以推翻旧设计，但替代方案落在*新 PRD 里*、写明它取代了什么；如果旧设计已经在某个跑到一半的分支上变成了代码，那么改这段代码就作为实打实的用户故事写进新 PRD，而不是假装它没被实现过。

### 阶段 2 —— 转换：`/ralph` 把 PRD 变成可执行的 run

对 PRD 运行 `/ralph`。这是一个思考步骤，不是机械转录：

1. **盘点在飞的 run** —— 和阶段 1 同一次盘点，但读法不同。在飞的 run 正是根级 `dependsOnRuns` 的来源：lint 能拒绝指向不存在的 run 的条目，却没办法发现一条你压根不知道要写的边。它同时挡住两件事——把别的 run 已经在做的切片重新拆一遍（两个分支改同一批文件，合并回来时撞车），以及把验收标准建立在只存在于未合并分支上的代码之上：本 run 的 worktree 是从基线分支切出来的，别的 run 里已经 `passes` 的故事在这里根本还不存在。
2. **方案校验** —— 从 PRD 的引言里还原用户的真实诉求，审视 PRD 中隐含的实现方案；如果存在明显更优的做法，先停下来与你确认方向。
3. **故事拆分** —— 从确认后的方案重新推导故事。第一铁律：**每个故事必须能在一个 agent 上下文窗口内完成**（"加一列字段 + 迁移"是合适的粒度，"做完整个看板"不是）。故事按依赖排序（schema → 后端 → UI），且每条真实依赖——构建依赖*和验证依赖*——都要显式写进故事的 `dependsOn`。每条验收标准都必须可机械验证（"typecheck 通过"可以，"工作正常"不行），**并且在本故事自己的回合内就能观察到**：一条要等后面的故事落地才能验证的标准，说明拆错的是故事而不是措辞。真正由多个独立可交付物组成的工作，应拆成多个 run、用根级 `dependsOnRuns` 连接，而不是堆成一条超长故事列表。
4. **依赖审计**（可选） —— 拆解的 agent 无权为自己画的依赖图签字，所以可以由一个*独立的* agent 只拿到源 PRD 和成稿的 `prd.json`（拿不到拆解者的任何推理过程），重新推导每一条 `dependsOn` 边，并复核所有 `Covers:` 子句是否铺满 `userNeed`。它的发现要么被采纳、要么被书面驳回，最终图记录进 `deps-audit.json`。真正要抓的是漏掉的*验证依赖*——某个故事被排在"能让人观察到它"的东西之前，这种问题在故事内部再怎么努力实现也解决不了。它多花一次 agent 调用，也没有任何东西强制它：图值得找人复核就跑，backlog 短或者本来就是线性的就跳过。
5. **run 脚手架** —— 写出 `ralph/runs/<run_id>/`：

```
ralph/runs/<run_id>/
├── prd.json                     # branchName、userNeed、userStories[]（passes:false）
├── progress.txt                 # 人类可读的进度日志
├── progress/shared-memory.json  # []——跨故事的模式/坑
├── deps-audit.json              # 可选：另一个 agent 对依赖图的独立复核结果
└── state.json                   # runId、baseBranch、baseSha、targetBranch、status
```

让"无记忆执行"得以成立的两个字段：

- **根级 `userNeed`** —— 经确认的业务语言需求陈述。循环在拆分故事时会把它复制进每个故事文件，因此每个 agent 不读完整 PRD 也能看到全局。
- 每个故事描述末尾的 **`Covers:` 子句** —— 声明本故事负责 `userNeed` 的哪一块。把所有 `Covers:` 连起来通读，必须恰好铺满整个需求，无缺口、无重叠。

`baseBranch` 取转换时你检出的分支——绝不假设是 `main`。

（已经有现成的 `prd.json`？用 `ralph/scripts/create-run.sh <run_id> path/to/prd.json` 可以生成同样的脚手架。）

`ralph/scripts/lint-prd.sh --run <run_id>` 负责校验产物：悬空、前向、自引用或成环的 `dependsOn`，以及指向不存在 run 的 `dependsOnRuns`，都会被拒绝。run 目录里如果有 `deps-audit.json`，它会与 `prd.json` **逐边比对**——所以审计跑完之后再去改某条 `dependsOn`，只会让审计作废，而不会让它悄悄蒙混过关。但这项比对和"审计文件缺失"都只打印 `WARN:`、不影响退出码：审计是建议，不是关卡。`ralph.sh` 启动时也会跑同一个 lint，PRD 不过就拒绝启动。（`RALPH_REQUIRE_DEPS_AUDIT=1` 把审计警告重新升级为错误；`RALPH_SKIP_DEPS_AUDIT=1` 则完全不提它。）

### 阶段 3 —— 执行：`ralph.sh` 循环，每个故事一个全新 agent

```sh
ralph/scripts/ralph.sh --run <run_id> --tool claude 20   # 或 --tool codex（默认）/ --tool pi
```

**启动（一次性）：**

1. 选定 run（`--run` 指定，或交互式列出未完成的 run 供选择），并占用锁目录 `ralph/locks/run-<run_id>.lock`，防止同一 run 被启动两次。
2. 读取 `state.json`；缺失的 `baseBranch`/`baseSha` 用当前检出状态回填。
3. 在 `.worktrees/<run_id>` 创建（或复用）git worktree，检出 `branchName`（如 `ralph/<feature>`，从基线分支创建），并在缺失时把 run 的输入文件复制进去。整个 run 都发生在 worktree 里——你的主工作区不受影响。
4. 检查 `dependsOnRuns` 门槛：本 run 依赖的每个 run 都必须已经 merge 回基线分支（或已归档），因为 worktree 是基线分支的快照，看不见未合并的工作。依赖未满足就拒绝启动（`RALPH_IGNORE_RUN_DEPS=1` 可降级为警告）；随后对 PRD 跑 lint（`lint-prd.sh`），lint 不过同样拒绝启动。
5. 把 `prd.json` 拆成单故事文件 `stories/US-xxx.json`，并把根级 `userNeed` 复制进每个文件。

**每个故事轮：**

1. 先把 `stories/*.json` 同步回 `prd.json`，然后取**第一个 `passes != true` 的故事**。
2. 拼装一次性 prompt，内容包括：
   - agent 行为手册——`scripts/CLAUDE.md`（`--tool claude` 时）、`scripts/CODEX.md`（`--tool codex` 时）或 `scripts/PI.md`（`--tool pi` 时）；
   - run 上下文（分支、worktree、各文件路径）；
   - **仅当前故事的 JSON**（并明确告知 agent 不要去读完整 PRD）；
   - **记忆切片**：最近约 40 条 shared-memory 条目 + 该故事最近约 5 条进度记录。
3. 在 worktree 里启动一个**全新的 agent 进程**（`claude --print …`、`codex exec …` 或 `pi --print --mode json …`，跳过权限确认——本循环就是为无人值守设计的）。没有聊天历史，没有上一轮的上下文。
4. agent 按手册行事：只实现**这一个故事**（只做 `Covers:` 指明的那一块），跑覆盖本次改动的质量检查（typecheck 加这一块的测试，而不是每轮重跑全量套件），把故事文件改为 `passes: true` 并写下 `notes`，用 `append-progress-json.sh` 追加结构化进度记录（一行 JSON 写进 `progress/<story_id>.jsonl`，可选 `--shared-memory` 沉淀可复用模式），最后以 `feat: [US-xxx] - [标题]` 提交全部变更。
   每个 agent 回合都会收到统一的 **Round Commit Contract**：本轮产生的所有预期仓库产物必须在本轮结束前提交，不能留给后续 story、finalization、merge-back 或 consolidation 代为提交；若只形成了安全且完整的阶段性成果，则提交 checkpoint，但仍保持故事未完成。运行时 marker、临时诊断文件和无产物的幂等重试不要求空提交。
5. 循环把故事状态同步回 `prd.json`（安全时 amend 进故事提交），并且**只认文件**。当前故事变为 `passes: true` 才正常进入下一故事；只要仍是 `passes != true`，无论 agent 口头上如何声明，都不会再重跑实现轮。
6. 未完成的故事只会额外触发一次**故事疏通轮**（`UNBLOCK_STORY.md`）。它会拿到当前故事、近期进度、前后 Git HEAD、上一轮 agent 消息，以及可用时的原始失败事件——但它不是一次重试。在写任何代码之前，它先回答一个问题：这个故事是**真的被阻塞**了，还是上一轮只是没做完？
   - **没被阻塞**（默认答案，也是常见答案：预算耗尽、方向走错、测试留着没修、状态忘了写）——它从上一轮已提交的 checkpoint 接着做，把故事完成。循环正常前进。
   - **真的被阻塞**——在这个故事自身的范围内，无论投入多少实现努力都不可能诚实满足它的验收标准：观察点落在后续故事里、故事根本没有可观测出口、验证设施要等后面的故事才建好、或者缺一条 `dependsOn` 边。这是切分缺陷，所以这一轮修的是切分：拆分故事、插入前置故事、重排顺序、补上缺失的边，或把某条验收标准搬到真正拥有该观察点的故事。它绝不允许削弱验收标准、丢掉 `userNeed` 的任何切片，或把任何故事标成通过。因为切分变了，已有的 `deps-audit.json` 就不再描述当前切分：这一轮要么通过一个全新的隔离 agent 重跑依赖审计（`DEPENDENCY_AUDIT.md`）并重写该文件，要么直接删掉它——绝不允许自己审自己的重构。然后到此为止、不做实现。Ralph 按新切分继续循环。
   - **两者都不是**——缺一个只有人能做的决定，或环境缺少任何轮次都造不出来的东西。Ralph 打印该轮的收尾消息后退出 `1`，后续轮次全部跳过。
7. 只有成功的故事轮会继续，直到所有故事通过。循环没有总轮数预算：一个故事要么完成，要么被重构绕开，要么在第 6 步终止整次运行。重构是失败唯一能把控制权交回循环的路径，所以它自带上限（`RALPH_MAX_RESTRUCTURES`，默认 2）——反复需要修的切分是 PRD 的问题，该交给人。真正可能自我重试的是收尾轮，它们各自带一个小预算（见下方 `RALPH_MAX_*_ROUNDS`）。

交互式终端的最底部会常驻一条进度栏，上方的 agent 日志照常滚动：

```
Ralph:20260817-a [█████░░░░░░░░░░░] 3/8 done | US-004 | working 4m12s | round 7 | total 1h06m | eta ~2h45m | ~$4.18 | 3.7M tok | 补齐成本统计
```

各段按优先级依次追加，终端越窄就从右侧越先脱落，因此 40 列的窗口里仍能看到进度条和当前故事。run id（legacy 模式下为分支名）从 90 列起显示——并行编排开多个窗口时，它是区分各个 run 的唯一标识。

其中两段只在有话可说时才出现：

- **`idle 2m05s/6m00s`**：agent 静默超过 `RALPH_PROGRESS_IDLE_MIN` 秒（默认 30）后出现，整行转为黄色，并一直数到会终止本次调用的空闲超时。没有它的话，一个跑了 5 分钟的测试和一个已经卡死的 CLI 看起来完全一样——阶段计时在两种情况下都照走。
- **`eta ~2h45m`**：只按**本次运行**完成的故事外推，因此续跑一个半成品 run 时，不会拿已耗时去除以上一次运行的成果。merge-back 和 consolidation 轮不算故事，所以临近收尾时估算会漂——这就是那个波浪号的含义。

后台心跳每 `RALPH_PROGRESS_TICK_SECONDS` 秒（默认 2）重绘一次，因此 agent 静默时计时仍在走；Ralph 被强杀时它也会自行恢复终端。输出被重定向到文件（包括并行编排日志）时会自动关闭——控制码只写 `/dev/tty`，绝不会进日志；设置 `RALPH_PROGRESS=0` 也可手动关闭。

### 日志配色

一轮会刷出成千上万行 agent 输出，因此真正说明「循环走到哪一步」的那几行是带颜色的。同一种颜色始终表示同一件事：

| 颜色 | 含义 |
|---|---|
| 青色 | 一个故事轮开始——`Ralph Round 7 (codex) - Target: US-004` |
| 黄色（加粗） | 故事修复轮（unblock round）及它做出的判定 |
| 品红 | merge-back 轮 |
| 蓝色 | consolidation 轮 |
| 绿色 | 一个故事、一次合并或整个 run 完成 |
| 黄色 | 循环会继续跑下去的告警 |
| 红色 | Ralph 即将停止 |

修复轮特意沿用进度栏的告警黄：两者都表示这次运行已经偏离正常路径。agent 自身的输出不会被重新上色，修复轮的收尾报告正文也不会——只有包住它的框线会。

颜色按输出流各自判定，且只写向交互式终端，因此被重定向的输出（并行编排日志、CI、`tee`）仍是逐字节一致的纯文本。`NO_COLOR` 会关闭它，`RALPH_LOG_COLOR=0` 强制关闭，`RALPH_LOG_COLOR=1` 强制开启——管进 `less -R` 时会用到。

### Token 与成本统计

Ralph 会把两个 agent CLI 各自上报的用量归一化，并在整个 run 内累加。进度栏里的实时总计和结束时打印在 stdout 上的账单出自同一份账本，所以进度栏关闭的非交互运行同样能拿到：

```
Ralph usage for this run:
  Tool calls:    12
  Model:         gpt-5.6-sol
  Input:         412000 (new) + 3140000 (cache read) + 88000 (cache write)
  Output:        61000
  Total tokens:  3701000
  Cost:          ~$4.18 (estimated at 5/0.5/6.25/30 USD per 1M in/cached/write/out)
```

金额从哪儿来取决于所用工具，进度栏也会把两者区分开——`$4.18` 是账单，`~$4.18` 是估算：

- **claude** 自己上报 `total_cost_usd`，因此 Ralph 直接采用 CLI 给出的数字，不自行计价。订阅制账户下这个数字是等价 API 价格，并非实际扣费。
- **codex** 只报 token 不报金额，因此 Ralph 按价格表估算。默认值为 gpt-5.6-sol 标准档（每百万 token：输入 $5、缓存命中 $0.50、缓存写入 $6.25、输出 $30）；换模型时请自行覆盖。输入超过 272K 的请求走更贵的长上下文档，而事件流并不逐请求暴露这一点，因此长期处于该档的 run 会被低估，除非你调高上述价格。
- **pi** 按自带的模型价目表逐条消息计价并上报结果，因此 Ralph 直接采用该金额和它给出的真实模型名——无论 pi 配置的是哪个 provider / 模型。pi 的 run 完全忽略 `RALPH_PRICE_*`。

防护措施：单次调用的空闲超时（默认静默 360 秒即终止）和可选的硬超时；命中限流时以专用退出码 75 中止整个循环；每次调用后清扫进程树，回收残留的 dev server / watcher（含 Windows Git Bash 的特殊处理）。Codex 使用 `--json`、pi 使用 `--mode json`，两者都保留各自的正常 session：Ralph 直接从管道实时解析 JSONL，只在内存环形缓冲中保留最近 100 条事件；仅当本次调用失败时，才把这些原始事件写入临时诊断文件。疏通轮会被指向该文件，可在判断发生了什么时读取它。

每一轮都是写权限轮——故事轮做实现，收尾轮做定稿与合并，疏通轮要么完成故事要么重塑待办列表——因此全部绕过权限确认运行（`claude --dangerously-skip-permissions`、`codex --dangerously-bypass-approvals-and-sandbox`、`pi --approve`，后者会信任项目本地的 `.pi/` 设置、扩展与技能）。

### 阶段 4 —— merge-back：分支合并回基线

当所有故事通过且 `branchName != baseBranch` 时：

1. 若 worktree 还有未提交产物，先跑一轮**收尾 agent 回合**把它们提交干净。
2. 循环取得合并锁，先自己走廉价路径：在基线工作区执行 `git merge --no-ff --no-commit ralph/<feature>` 再提交——产生真实的双父合并提交，故事提交在历史里保持可见。
3. 若合并冲突（或基线工作区有未提交改动），则启动**专门的 merge-back agent 回合**（`MERGE_BACK.md`）：审慎解决冲突，禁止 rebase/squash/abort，保护本地改动，完成合并提交后写入 `.merge-back-done` 标记文件。

循环只认标记文件，不认 agent 的口头声明。

### 阶段 5 —— consolidation 与归档：让知识活得比 run 久

在基线分支上再跑一轮 agent（`CONSOLIDATE.md`）：

1. 通读本次 run 的全部产出——`prd.json`、故事文件、`progress/*.jsonl`。
2. 把"**设计现在是什么样**"蒸馏进 `docs/design-ledger/<area>.md`（每个受影响的代码区域一个文件）。ledger 是"X 现在是怎么工作的"的权威答案——未来的 agent 读它，而不是去翻历史 PRD。
3. 给源 PRD `ralph/tasks/prd-<run_id>.md` 加上 `status: merged` frontmatter，指向对应的 ledger 文件。
4. 写入 consolidation 标记；随后 `ralph.sh` 机械地把 `ralph/runs/<run_id>/` 和源 PRD `ralph/tasks/prd-<run_id>.md` 一起移到 `ralph/archive/<date>-<run_id>/`，并把这次移动提交成一个单独的归档提交。`ralph/tasks/` 因此只保留还在进行中的 PRD，已完成的 run 与它的 PRD 文档留在同一个归档目录里。

循环以退出码 0 结束，并发送桌面通知。

### 无记忆的 agent 之间如何共享知识

每一轮都是冷启动，所以一切记忆都是文件：

| 记忆载体 | 作用域 | 写入者 | 是否注入 prompt？ |
|---|---|---|---|
| `stories/<id>.json`（`userNeed` + `Covers:`） | 单个故事 | `/ralph` + 循环 | 是——整个文件 |
| `progress/<id>.jsonl` | 单个故事 | `append-progress-json.sh` | 最近约 5 条 |
| `progress/shared-memory.json` | 单个 run | `append-progress-json.sh --shared-memory` | 最近约 40 条 |
| 源码目录旁的 `CLAUDE.md` | 整个仓库 | agent 发现可复用知识时 | 由 agent 自身工具读取 |
| `docs/design-ledger/<area>.md` | 仓库级、永久 | consolidation 回合 | 未来 run 按需读取 |

### 多 run 编排：`orchestrate.sh`

```sh
ralph/scripts/orchestrate.sh --tool claude                        # 图模式：按 dependsOnRuns 调度
ralph/scripts/orchestrate.sh --tool claude --plan "1 > 2,3 > 4"   # 手工阶段计划
```

不带 `--plan` 时，编排器读取各未完成 run 的 `dependsOnRuns` 并按依赖图调度：依赖已全部 merge 回基线的 run 立即启动，互相独立的 run 并行执行，某个 run 失败只会阻塞它的传递下游，收尾时汇总列出成功 / 失败 / 被阻塞三组。`--graph` 可在没有任何依赖声明时也强制图模式；`--dry-run` 只预览波次不执行。

`--plan "1 > 2,3 > 4"` 保留手工阶段计划：`,` 表示同阶段并行，`>` 表示进入下一阶段，任一阶段失败即停止编排。两种模式下并行 run 的输出都写入各自的日志文件，命中限流会停止一切；run 级锁加基线分支级合并锁，保证并行 run 互不踩踏。

### 参数与环境变量

| 参数 / 环境变量 | 默认值 | 含义 |
|---|---|---|
| `--run <run_id>` / `RALPH_RUN_ID` | 交互式选择 | 执行哪个 run |
| `--tool claude\|codex\|pi` / `RALPH_TOOL` | `codex` | 用哪个 agent CLI 驱动每一轮 |
| `--legacy` | — | 单 run 模式，使用根级 `ralph/prd.json`（无 run 目录） |
| `RALPH_TOOL_IDLE_TIMEOUT_SECONDS` | `360` | agent 静默多久后终止本次调用 |
| `RALPH_TOOL_TIMEOUT_SECONDS` | `0`（关闭） | 单次调用硬上限 |
| `RALPH_SHARED_MEMORY_ITEMS` / `RALPH_STORY_PROGRESS_RECORDS` | `40` / `5` | prompt 记忆切片大小 |
| `RALPH_PROGRESS` | `1` | 交互式终端底部的常驻故事进度栏；设为 `0` 关闭 |
| `RALPH_PROGRESS_IDLE_MIN` | `30` | agent 静默多少秒后显示空闲计时 |
| `RALPH_LOG_COLOR` | `auto` | 循环自身状态行的配色；`0` 强制纯文本，`1` 即使被重定向也强制上色（`NO_COLOR` 同样可关闭）|
| `RALPH_MAX_FINALIZE_ROUNDS` / `RALPH_MAX_MERGE_BACK_ROUNDS` / `RALPH_MAX_CONSOLIDATION_ROUNDS` | 各 `3` | 单个收尾轮最多自我重试几次，超出就停下 |
| `RALPH_PRICE_INPUT_USD` / `RALPH_PRICE_CACHED_INPUT_USD` | `5` / `0.5` | 每百万 token 美元单价，用于估算 codex 成本（claude 与 pi 自报金额）|
| `RALPH_PRICE_CACHE_WRITE_USD` / `RALPH_PRICE_OUTPUT_USD` | `6.25` / `30` | 每百万 token 美元单价，用于估算 codex 成本（claude 与 pi 自报金额）|
| `RALPH_PRICE_MODEL` | `gpt-5.6-sol` | 估算成本时显示的模型标签 |
| `RALPH_NOTIFY` / `RALPH_NOTIFY_SOUND` | `1` | 桌面通知 |
| `RALPH_PLAN` | — | `orchestrate.sh` 的默认计划 |
| `RALPH_IGNORE_RUN_DEPS` | `0` | 设为 `1` 时，即使 `dependsOnRuns` 尚未 merge 回基线也照常启动 |
| `RALPH_REQUIRE_DEPS_AUDIT` | `0` | 设为 `1` 时，把 `deps-audit.json` 的建议性警告重新升级为 lint 错误 |
| `RALPH_SKIP_DEPS_AUDIT` | `0` | 设为 `1` 时，lint run 级 PRD 完全不提 `deps-audit.json` |
| `RALPH_MAX_RESTRUCTURES` | `2` | 单次运行中疏通轮最多可以重塑待办列表几次，超过即停止 |

退出码：`0` 全部完成，`1` 故事经疏通轮后仍失败/触顶重构次数上限/某个收尾轮用尽预算，`75` 命中限流，`124` 工具超时。

## 安装

无需 `npm publish`，直接从 GitHub 安装：

```sh
# 首次安装到当前项目：
npx github:levinhen/ralph-kit init

# 把已安装项目升级到最新版本：
npx github:levinhen/ralph-kit sync

# 诊断安装状态、检查是否过期：
npx github:levinhen/ralph-kit doctor
```

`init` 或 `sync` 完成后，ralph-kit 会尽力创建一个 Git 提交，且只包含本次动作创建或更新的文件。Git 提交失败（例如目标不在 Git 仓库中，或未配置提交者身份）时会静默忽略，不会导致命令失败。

## 安全保证

`init` 和 `sync` **绝不**触碰：

- `ralph/tasks/` —— `/prd` 技能写出的 PRD markdown
- `ralph/runs/` —— 进行中的 Ralph run
- `ralph/archive/` —— 已完成/已沉淀的 run 及其源 PRD markdown
- `ralph/locks/` —— 运行时锁目录
- `ralph/progress/`、`ralph/stories/`、`ralph/prd.json`、`ralph/progress.txt`、`ralph/state.json`、`ralph/.last-branch`、`ralph/.merge-back-done` —— legacy 模式的运行时文件
- 已存在的 `AGENTS.md` —— 片段会打印出来，由你自行粘贴

其余每个文件：

- **目标不存在** → 写入。
- **目标与模板完全一致** → 跳过（幂等）。
- **目标与模板不同** → `init` 跳过并警告；`sync` 直接用 kit 版本覆盖。

随时运行 `ralph-kit doctor` 查看漂移情况。

## 来源与致谢

核心 Ralph 循环（`ralph/scripts/`）派生自 [snarktank/ralph](https://github.com/snarktank/ralph)（MIT 协议，原始布局在 `scripts/ralph/` 下）。本 kit 在其基础上增加了：

- 多 agent 支持（`CLAUDE.md` + `CODEX.md` + `PI.md` 按 agent 区分的提示词）。
- run 作用域布局（`runs/<run_id>/`），含 consolidation 与 merge-back 回合。
- 配套 Claude Code 技能（`/prd`、`/ralph`）。
- 一个跨项目保持副本同步的 CLI 安装器。

完整版权说明见 [`LICENSE`](./LICENSE)。
