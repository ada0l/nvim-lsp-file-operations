local M = {}

local log = require("lsp-file-operations.log")

local default_config = {
  debug = false,
  timeout_ms = 10000,
  operations = {
    willRenameFiles = true,
    didRenameFiles = true,
    willCreateFiles = true,
    didCreateFiles = true,
    willDeleteFiles = true,
    didDeleteFiles = true,
  },
}

local modules = {
  willRenameFiles = "lsp-file-operations.will-rename",
  didRenameFiles = "lsp-file-operations.did-rename",
  willCreateFiles = "lsp-file-operations.will-create",
  didCreateFiles = "lsp-file-operations.did-create",
  willDeleteFiles = "lsp-file-operations.will-delete",
  didDeleteFiles = "lsp-file-operations.did-delete",
}

---@alias HandlerMap table<string, string[]> a mapping from modules to events that trigger it

--- helper function to subscribe events to a given module callback
---@param op_events HandlerMap the table that maps modules to event strings
---@param subscribe fun(module: string, event: string) the function for how to subscribe a module to an event
local function setup_events(op_events, subscribe)
  for operation, enabled in pairs(M.config.operations) do
    if enabled then
      local module, events = modules[operation], op_events[operation]
      if module and events then
        vim.tbl_map(function(event)
          subscribe(module, event)
        end, events)
      end
    end
  end
end

M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", default_config, opts or {})
  if M.config.debug then
    log.level = "debug"
  end

  -- nvim-tree integration
  local ok_nvim_tree, nvim_tree_api = pcall(require, "nvim-tree.api")
  if ok_nvim_tree then
    log.debug("Setting up nvim-tree integration")

    ---@type HandlerMap
    local nvim_tree_event = nvim_tree_api.events.Event
    local events = {
      willRenameFiles = { nvim_tree_event.WillRenameNode },
      didRenameFiles = { nvim_tree_event.NodeRenamed },
      willCreateFiles = { nvim_tree_event.WillCreateFile },
      didCreateFiles = { nvim_tree_event.FileCreated, nvim_tree_event.FolderCreated },
      willDeleteFiles = { nvim_tree_event.WillRemoveFile },
      didDeleteFiles = { nvim_tree_event.FileRemoved, nvim_tree_event.FolderRemoved },
    }
    setup_events(events, function(module, event)
      nvim_tree_api.events.subscribe(event, function(args)
        require(module).callback(args)
      end)
    end)
  end

  -- neo-tree integration
  local ok_neo_tree, neo_tree_events = pcall(require, "neo-tree.events")
  if ok_neo_tree then
    log.debug("Setting up neo-tree integration")

    ---@type HandlerMap
    local events = {
      willRenameFiles = { neo_tree_events.BEFORE_FILE_RENAME, neo_tree_events.BEFORE_FILE_MOVE },
      didRenameFiles = { neo_tree_events.FILE_RENAMED, neo_tree_events.FILE_MOVED },
      didCreateFiles = { neo_tree_events.FILE_ADDED },
      didDeleteFiles = { neo_tree_events.FILE_DELETED },
      -- currently no events in neo-tree for before creating or deleting, so unable to support those file operations
      -- Issue to add the missing events: https://github.com/nvim-neo-tree/neo-tree.nvim/issues/1276
    }
    setup_events(events, function(module, event)
      -- create an event name based on the module and the event
      local id = ("%s.%s"):format(module, event)
      -- just in case setup is called twice, unsubscribe from event
      neo_tree_events.unsubscribe({ id = id })
      neo_tree_events.subscribe({
        id = id,
        event = event,
        handler = function(args)
          -- translate neo-tree arguemnts to the same format as nvim-tree
          if type(args) == "table" then
            args = { old_name = args.source, new_name = args.destination }
          else
            args = { fname = args }
          end
          -- load module and call the callback
          require(module).callback(args)
        end,
      })
    end)
    log.debug("Neo-tree integration setup complete")
  end

  -- mini.files integration
  local ok_mini_files, _ = pcall(require, "mini.files")
  if ok_mini_files then
    log.debug("Setting up nvim-tree integration")

    local events = {
      willRenameFiles = { "MiniFilesActionRename" },
      willCreateFiles = { "MiniFilesActionCreate" },
      willDeleteFiles = { "MiniFilesActionDelete" },
    }
    setup_events(events, function(module, pattern)
      vim.api.nvim_create_autocmd("User", {
        pattern = pattern,
        callback = function(event)
          local args = {}
          local data = event.data
          if data.from == nil or data.to == nil then
            args = { fname = data.from or data.to }
          else
            args = { old_name = data.from, new_name = data.to }
          end
          require(module).callback(args)
        end,
      })
    end)
  end
end

return M
