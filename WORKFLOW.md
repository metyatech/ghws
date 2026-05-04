---
tracker:
  kind: linear
  team: ENG
  project_slug: ENG-1
  trigger_label: symphony

workspaces_root: ./workspaces

repositories:
  owner: metyatech
  protocol: https

agent:
  command: opencode
---
# Task from Linear: {{ issue.title }}

{{ issue.description }}

---
## Targets
{% for r in repos %}
- {{ r.name }} ({{ r.path }})
{% endfor %}
