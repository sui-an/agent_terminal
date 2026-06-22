#compdef agentforward

# Zsh completion for agentforward
_agentforward() {
    local -a commands agents
    commands=("list:List running agents" "help:Show help")

    if (( $+commands[jq] )) && [[ -n "${AGENTTERMINAL_SURFACE_ID:-}" ]] && [[ -n "${AGENTTERMINAL_HOOK_BIN:-}" ]]; then
        local agents_json
        agents_json=$("$AGENTTERMINAL_HOOK_BIN" claude list 2>/dev/null)
        if [[ -n "$agents_json" ]]; then
            agents=(${(f)"$(echo "$agents_json" | jq -r '.agents[].agent' 2>/dev/null)"})
        fi
    fi

    _arguments \
        '1: :->agent_or_command' \
        '*: :->message'

    case $state in
        agent_or_command)
            _describe -t commands 'command' commands
            if (( ${#agents} )); then
                _describe -t agents 'agent' agents
            fi
            ;;
        message)
            _message 'message content'
            ;;
    esac
}

_agentforward "$@"
