# Fish completion for agentforward
complete -c agentforward -f

function __agentforward_agents
    set -l surface_id $AGENTTERMINAL_SURFACE_ID
    if test -n "$surface_id"; and test -n "$AGENTTERMINAL_HOOK_BIN"
        $AGENTTERMINAL_HOOK_BIN claude list 2>/dev/null | jq -r '.agents[].agent' 2>/dev/null
    end
end

function __agentforward_commands
    echo list
    echo help
end

complete -c agentforward -n '__fish_use_subcommand' -a '(__agentforward_commands)' -d 'Command'
complete -c agentforward -n '__fish_use_subcommand' -a '(__agentforward_agents)' -d 'Agent'
complete -c agentforward -n '__fish_seen_subcommand_from list help' -f
