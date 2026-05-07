---
tracker:
  kind: linear
  team: ENG
  trigger_label: symphony

workspaces_root: ./workspaces

repositories:
  owner: metyatech
  protocol: https
  required: true
  local:
    prefer_existing: true
    roots:
      - .

agent:
  command: codex app-server

codex:
  approval_policy: never
---
# Task from Linear: {{ issue.title }}

{{ issue.description }}

---
## Targets
{% for r in repos %}
- {{ r.name }} ({{ r.path }})
{% endfor %}

---
## System Instructions for Linear
To leave a comment or update the status of this Linear issue, you MUST use the `linear_graphql` tool provided in your environment. 
- DO NOT use a web browser to access Linear.
- The ID of this issue is `{{ issue.id }}`.
- Use the `commentCreate` mutation to post your final report/plan.
- Use the `issueUpdate` mutation to change the state. If you do not know the `stateId` for "Done" or "Completed", query the workflow states for this team using `linear_graphql` first to find it.
