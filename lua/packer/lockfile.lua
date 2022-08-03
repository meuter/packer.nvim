local a = require 'packer.async'
local util = require 'packer.util'
local log = require 'packer.log'
local plugin_utils = require 'packer.plugin_utils'
local plugin_complete = require('packer').plugin_complete
local result = require 'packer.result'
local async = a.sync
local await = a.wait
local fmt = string.format

local config = {}

local lockfile = {}

lockfile.cfg = function(_config)
  config = _config
end

local function collect_commits(plugins)
  local completed = {}
  local failed = {}
  local opt, start = plugin_utils.list_installed_plugins()
  local installed = vim.tbl_extend('error', start, opt)

  plugins = vim.tbl_filter(function(plugin)
    if installed[plugin.install_path] and plugin.type == plugin_utils.git_plugin_type then -- this plugin is installed
      return plugin
    end
  end, plugins)

  return async(function()
    for _, plugin in pairs(plugins) do
      local rev = await(plugin.get_rev())
      if rev.err then
        failed[plugin.short_name] =
          fmt("Snapshotting %s failed because of error '%s'", plugin.short_name, vim.inspect(rev.err))
      else
        completed[plugin.short_name] = { commit = rev.ok }
      end
    end

    return result.ok { failed = failed, completed = completed }
  end)
end

lockfile.update = function(plugins)
  local lines = {}
  return async(function()
    local commits = await(collect_commits(plugins))

    for name, commit in pairs(commits.ok.completed) do
      lines[#lines + 1] = fmt([[  ["%s"] = { commit = "%s" },]], name, commit.commit)
    end

    table.sort(lines)
    table.insert(lines, 1, 'return = {')
    table.insert(lines, '}')

    await(a.main)
    local status, res = pcall(function()
      return vim.fn.writefile(lines, config.lockfile.path) == 0
    end)

    if status and res then
      return result.ok {
        message = fmt('Lockfile written to %s', config.lockfile.path),
        failed = commits.ok.failed,
      }
    else
      return result.err { message = fmt("Error on creating lockfile '%s': '%s'", config.lockfile.path, res) }
    end
  end)
end

return lockfile
