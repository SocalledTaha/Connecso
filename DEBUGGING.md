# Debugging

The UI must show concise human-readable errors. Use structured internal categories (`network`, `node`, `configuration`, `core`, `verification`, `permission`) without logging node secrets. A connected status requires verified routed connectivity. When investigating a failed CI run, inspect the first root-cause compiler/dependency error, fix the source or pin the affected tool version, and rerun the same workflow.
