## Progress Report Format

Write one small JSON object to a temp file like this, then run the append command from `Ralph Current Story Context`:

```json
{
  "timestamp": "YYYY-MM-DD HH:MM",
  "storyId": "US-001",
  "summary": "What was implemented",
  "filesChanged": ["path/to/file"],
  "checks": ["command: result"],
  "learnings": {
    "patterns": [],
    "gotchas": [],
    "context": []
  }
}
```
