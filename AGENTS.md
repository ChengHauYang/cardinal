# Cardinal Agent Instructions

`CLAUDE.md` is a symlink to this file so both agents use the same instructions.

Before building, testing, or running Cardinal, source the repository environment in the same shell:

```bash
source cardinal_env.sh
```

For example:

```bash
source cardinal_env.sh && ./cardinal-opt -i path/to/input.i --check-input
```

Do not replace this with `conda run`; `cardinal_env.sh` configures the complete Cardinal environment.
