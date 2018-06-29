--
-- Lua bridge for some of the git commands.
--
local os = require('os')

--
-- Exec a git command.
-- @param params Table of parameters:
--        * options - git options.
--        * cmd - git command.
--        * args - command arguments.
--        * dir - working directory.
--        * fout - write output to the file.
local function exec_cmd(params)
    local fout = params.fout
    local shell_cmd = {'git'}
    for _, param in pairs({'options', 'cmd', 'args'}) do
        table.insert(shell_cmd, params[param])
    end
    if fout then
        table.insert(shell_cmd, ' >' .. fout)
    end
    shell_cmd = table.concat(shell_cmd, ' ')
    if params.dir then
        shell_cmd = string.format('cd %s && %s', params.dir, shell_cmd)
    end
    local res = os.execute(shell_cmd)
    assert(res == 0, 'Git cmd error: ' .. res)
end

local function log_hashes(params)
    params.args = "--format='%h' " .. params.args
    -- Store log to the file.
    local temp_file = os.tmpname()
    params.fout = temp_file
    params.cmd = 'log'
    exec_cmd(params)
    local lines = {}
    for line in io.lines(temp_file) do
        table.insert(lines, line)
    end
    os.remove(temp_file)
    return lines
end

return {
    exec_cmd = exec_cmd,
    log_hashes = log_hashes
}
