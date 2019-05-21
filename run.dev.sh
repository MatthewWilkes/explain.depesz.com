#!/usr/bin/env bash
# make sure that current dir is project top dir
this_script="${BASH_SOURCE[0]}"
script_directory="$( dirname "${this_script}" )"
work_dir="$( readlink -f "${script_directory}" )"
cd "$work_dir"
# make sure that current dir is project top dir

project_name=explain

# I use ssh-ident tool (https://github.com/ccontavalli/ssh-ident), so I should
# set some env variables.
ssh_ident_agent_env="${HOME}/.ssh/agents/agent-priv-$( hostname -s )"
[[ -e "${ssh_ident_agent_env}" ]] && . "${ssh_ident_agent_env}" > /dev/null

# Check if the session already exist, and if yes - attach, with no changes
tmux has-session -t "${project_name}" 2> /dev/null && exec tmux attach-session -t "${project_name}"

tmux new-session -d -s "${project_name}" -n "morbo"
tmux bind-key c new-window -c "#{pane_current_path}" -a

tmux new-window -d -n shell -t "${project_name}"

for dir in lib templates public/css public/js
do
    tmux new-window -d -n "${dir##*/}" -t "${project_name}" -c "${work_dir}/${dir}/"
done

tmux split-window -d -t "${project_name}:morbo"

tmux send-keys -t "${project_name}:morbo.0" "morbo -v -l http://*:25634 ${project_name}.pl" Enter

tmux send-keys -t "${project_name}:morbo.1" "tail -F log/development.log" Enter

for d in shell lib templates css js
do
    tmux send-keys -t "${project_name}:${d}" "ls -l" Enter
done

tmux attach-session -t "${project_name}"
