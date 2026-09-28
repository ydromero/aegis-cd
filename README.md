#CD Aegis 🛡️

**Aegis CD** is an *Agentic CI/CD* framework designed to execute surgical code modifications in production repositories without the risk of hallucinations, scope creep, or Remote Code Execution (RCE).

Unlike traditional autonomous frameworks (where an LLM agent operates in an open loop—`while True`—with unrestricted terminal access), Aegis CD inverts control: **the workflow is a deterministic state machine governed by POSIX scripts (Bash)**. Agents are instantiated as ephemeral subprocesses, equipped with dynamically stripped-down toolsets and no authority to decide when to delegate tasks.

## 🏗️ Security Architecture (Hard Sandboxing)

Aegis CD decouples core logic from project configuration (Stack Profiles). Security rests on three pillars:

1. **Dynamic Tool Stripping:** The Executor and QA agents **do not have access to Bash**. The orchestrator executes tests securely (e.g., by pre-validating that the local database is not used) and passes the results to the QA agent via a static text file (`.txt`).
2. **Cryptographic Sealing (Gate 2):** AI-generated plans do not execute automatically. They require human approval, which seals the file using `chmod a-w` and a SHA-256 hash. If the IDE or a human alters even a single byte of the plan, execution is blocked.
3. **Strict Scope Auditing:** Before and after the QA phase, the orchestrator captures a fingerprint (`tree_snapshot`) of the Git tree, excluding runtime directories (e.g., `storage/`). If the AI ​​modifies unauthorized code, the pipeline is aborted. ## 🔄 The Surgical Pipeline (4 Phases)

1. **Analyst (`analyst.md`):** Explores the code (`read`, `grep`, `find`) to diagnose the root cause of the issue. **Gate 1:** If the case is classified as a *Report* (UI changes or ambiguity) rather than a *Direct Bug*, the flow halts to request human intervention.
2. **Architect (`architect.md`):** Validates the Analyst's findings and designs a line-by-line execution plan.
3. **Executor (`executor.md`):** Receives the finalized plan and applies precise modifications using exclusively the `edit` tool.
4. **QA (`qa.md`):** Audits the changes. Reviews the `git diff` and the results of tests pre-calculated by the orchestrator. Determines whether the code proceeds to commit (`PASS`), requires review (`MANUAL_REQUIRED`), or fails (`FAIL`). ## 🚀 Installation and Usage

Install Aegis CD in your local project by linking your stack profiles (e.g., Laravel):

```bash
# Link agents and configuration to the current repository
/path/to/aegis-cd/install.sh /path/to/your/project
```

### Daily Workflow

```bash
# 1. Start an analysis and generate the plan (Phases 1 and 2)
./bin/orquestador "The login button returns a 500 error"

# 2. Approve and cryptographically seal the plan (Gate 2)
./bin/orquestador --aprobar [ISSUE_ID]

# 3. Execute modifications on target files
./bin/orquestador --ejecutar [ISSUE_ID]

# 4. Audit scope and run blind QA
./bin/orquestador --qa [ISSUE_ID]
```