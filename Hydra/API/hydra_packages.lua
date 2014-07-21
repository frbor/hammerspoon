--- === hydra.packages ===
---
--- Package management for third party Hydra libraries.
---
--- Put `hydra.packages.setup()` at the top of your initfile; it does nothing if it's already been setup.
---
--- See `hydra.packages.list` and `hydra.packages.install` to get started.

hydra.packages = {}

--- hydra.packages.setup()
--- Clones https://github.com/sdegutis/hydra-ext into ~/.hydra-ext if it's not already there.
function hydra.packages.setup()
  -- TODO
end

--- hydra.packages.list()
--- Lists available and installed packages.
function hydra.packages.list()
  -- TODO
end

--- hydra.packages.listinstalled()
--- Lists only installed packages.
function hydra.packages.listinstalled()
  -- TODO
end

--- hydra.packages.install(...)
--- Installs the given package.
function hydra.packages.install(...)
  -- TODO
end