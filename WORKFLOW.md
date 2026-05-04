linear:
  team: ENG
  trigger_label: symphony

workspaces_root: ./workspaces

repositories:
  owner: metyatech
  protocol: https

agent:
  command: opencode
  prompt: |
    # Task from Linear: {{ issue.title }}
    
    {{ issue.description }}
    
    ---
    ## 対象リポジトリ
    {% for r in repos %}
    - {{ r.name }} ({{ r.path }})
    {% endfor %}
