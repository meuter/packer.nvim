local a = require 'packer.async'
local plugin_utils = require 'packer.plugin_utils'
local result = require 'packer.result'
local async = a.sync
local await = a.wait
local fmt = string.format

local config = {}
local data = {}

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
    if installed[plugin.install_path] then -- this plugin is installed
      return plugin
    end
  end, plugins)

  return async(function()
    for _, plugin in pairs(plugins) do
      local name = plugin.short_name
      if plugin.type == plugin_utils.local_plugin_type then
        -- If a local plugin exists in the current lockfile data then use that to keep conistant.
        -- Note: Since local plugins are ignored by the lockfile it will not try and change the local repo.
        if data[name] then
          completed[name] = data[name]
        end
      else
        local rev = await(plugin.get_rev())
        local date = await(plugin.get_date())
        if rev.err then
          failed[name] = fmt("Getting rev for '%s' failed because of error '%s'", name, vim.inspect(rev.err))
        elseif date.err then
          failed[name] = fmt("Getting date for '%s' failed because of error '%s'", name, vim.inspect(date.err))
        else
          completed[name] = { commit = rev.ok, date = date.ok }
        end
      end
    end

    return result.ok { failed = failed, completed = completed }
  end)
end

---Loads the lockfile module and returns the result
lockfile.load = function()
  local module = config.lockfile.module

  -- Handle impatient.nvim
  local luacache = (_G.__luacache or {}).cache
  if luacache then
    luacache[module] = nil
  end

  package.loaded[module] = nil
  data = require(config.lockfile.module)
end

---Apply lockfile to plugin
---@param plugin table
lockfile.apply = function(plugin)
  -- Lockfile is not applied for local plugins and plugins that contain `tag` keys
  if plugin.type == plugin_utils.local_plugin_type or plugin.tag then
    return
  end

  local name = plugin.short_name
  if data[name] then
    plugin.commit = data[name]
  end

  if plugin.requires then
    local reqs = {}
    if type(plugin.requires) == 'string' then
      plugin.requires = { plugin.requires }
    end

    for _, req in ipairs(plugin.requires) do
      lockfile.apply(req)
      reqs[#reqs + 1] = req
    end

    plugin.requires = reqs
  end
end

---Update lockfile with the current installed state
---@param plugins table
lockfile.update = function(plugins)
  local lines = {}
  return async(function()
    local commits = await(collect_commits(plugins))

    for name, commit in pairs(commits.ok.completed) do
      lines[#lines + 1] = fmt([[  ["%s"] = { commit = "%s", date = %s },]], name, commit.commit, commit.date)
    end

    -- Lines are sorted so that the diff will only contain changes not random re-ordering
    table.sort(lines)
    table.insert(lines, 1, 'return {')
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

---Get lockfile data
---@return table
lockfile.get_data = function()
  return data
end

return lockfile
