# Bash completion for agentforward
_agentforward_completion() {
    local cur prev commands agents
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="list help"

    if [ "$COMP_CWORD" -eq 1 ]; then
        if command -v jq &>/dev/null && [ -n "${AGENTTERMINAL_SURFACE_ID:-}" ] && [ -n "${AGENTTERMINAL_HOOK_BIN:-}" ]; then
            agents=$("$AGENTTERMINAL_HOOK_BIN" claude list 2>/dev/null | jq -r '.agents[].agent' 2>/dev/null)
            COMPREPLY=( $(compgen -W "$commands $agents" -- "$cur") )
        else
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        fi
        return 0
    fi

    if [ "$prev" = "list" ] || [ "$prev" = "help" ]; then
        return 0
    fi

    return 0
}

complete -F _agentforward_completion agentforward
