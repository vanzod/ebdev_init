--------------------------------------------------------------------------
-- This is a placeholder for site specific functions.
-- @module SitePackage

require("strict")

---------------------------------------------------------------------------------------
----------------------------- Azure HPC Custom Hooks ----------------------------------
---------------------------------------------------------------------------------------

local hook = require("Hook")

-----------------------------------------
---  Replace module avail paths       ---
---  with more intuitive labels.      ---
---  Also merge GCCcore modules with  ---
---  either Intel or GCC modules      ---
---  to avoid user confusion.         ---
-----------------------------------------

local dbg  = require("Dbg"):dbg()

local red = "\027\[01;31m"
local green = "\027\[01;32m"
local yellow = "\027\[01;33m"
local yellow = "\027\[01;34m"
local purple = "\027\[01;35m"
local cyan = "\027[01;36m"
local normal = "\027\[0m"

-- Add function to split string (str) into table
-- at given separator occurrences (pat)
function split(str, pat)
   local t = {}  -- NOTE: use {n = 0} in Lua-5.0
   local fpat = "(.-)" .. pat
   local last_end = 1
   local s, e, cap = str:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
         table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
   end
   if last_end <= #str then
      cap = str:sub(last_end)
      table.insert(t, cap)
   end
   return t
end

function avail_labels_hook(t)

   local core_str = "Core Modules"
   local app_str = "Applications built with "

   -- Find compiler and MPI versions
   -- If not found, value is left to false (boolean)
   local versions = {gcc=false, intel=false, ompi=false, impi=false, hpcx=false, cuda=false}
   for k,v in pairs(t) do
      if (k:find("Compiler/GCC/")) then
         local split_module_path = split(k, "/")
         versions.gcc = split_module_path[#split_module_path]
      elseif (k:find("Compiler/intel/")) then
         local split_module_path = split(k, "/")
         versions.intel = split_module_path[#split_module_path]
      elseif (k:find("/OpenMPI/")) then
         local split_module_path = split(k, "/")
         versions.ompi = split_module_path[#split_module_path]
      elseif (k:find("/impi/")) then
         local split_module_path = split(k, "/")
         versions.impi = split_module_path[#split_module_path]
      elseif (k:find("/HPC%-X/")) then
         local split_module_path = split(k, "/")
         versions.hpcx = split_module_path[#split_module_path]
      elseif (k:find("Compiler/GCC%-CUDA/") or k:find("MPI/GCC%-CUDA/")) then
         local split_module_path = split(k, "/")
         versions.cuda = split(split(k, "/")[8], "-")[3]
      elseif (k:find("Compiler/intel%-CUDA/") or k:find("MPI/intel%-CUDA/")) then
         local split_module_path = split(k, "/")
         versions.cuda = split(split(k, "/")[8], "-")[2]
      end
   end

   -- Dynamically generated lables map table
   local azurehpc = {}

   azurehpc["Core"] = cyan.."Compilers, Toolchains and Binary Distributed Software"..normal

   if versions.gcc then
      azurehpc["Compiler/GCC/"] = cyan.."Applications built with GCC "..versions.gcc..normal
      azurehpc["Compiler/GCCcore/"] = azurehpc["Compiler/GCC/"]
      if versions.cuda then
      	 azurehpc["Compiler/GCC%-CUDA/"] = cyan.."Applications built with GCC "..versions.gcc.." + CUDA "..versions.cuda..normal
      end
      if versions.ompi then
         if versions.cuda then
            azurehpc["MPI/GCC%-CUDA/"] = cyan.."Applications built with GCC "..versions.gcc.." + CUDA "..versions.cuda.." + OpenMPI "..versions.ompi..normal
         else
            azurehpc["MPI/GCC/"] = cyan.."Applications built with GCC "..versions.gcc.." + OpenMPI "..versions.ompi..normal
         end
      end
      if versions.hpcx then
         if versions.cuda then
            azurehpc["MPI/GCC%-CUDA/"] = cyan.."Applications built with GCC "..versions.gcc.." + CUDA "..versions.cuda.." + HPC-X "..versions.hpcx..normal
         else
            azurehpc["MPI/GCC/"] = cyan.."Applications built with GCC "..versions.gcc.." + HPC-X "..versions.hpcx..normal
         end
      end
   elseif versions.intel then
      azurehpc["Compiler/intel/"] = cyan.."Applications built with Intel "..versions.intel..normal
      azurehpc["Compiler/GCCcore"] = cyan["Compiler/intel/"]
      if versions.cuda then
         azurehpc["Compiler/intel%-CUDA/"] = cyan.."Applications built with Intel "..versions.intel.." + CUDA "..versions.cuda..normal
      end
      if versions.impi then
         if versions.cuda then
            azurehpc["MPI/intel%-CUDA/"] = cyan.."Applications built with Intel "..versions.intel.." + CUDA "..versions.cuda.." + IntelMPI "..versions.impi..normal
         else
            azurehpc["impi"] = cyan.."Applications built with Intel "..versions.intel.." + IntelMPI "..versions.impi..normal
         end
      end
   end

   -- Group specific labels

   local mapT = {}
   mapT.azurehpc = azurehpc

   local availStyle = masterTbl().availStyle
   dbg.print{"avail hook called: availStyle: ",availStyle,"\n"}
   local styleT = mapT[availStyle]
   if (not availStyle or availStyle == "system" or styleT == nil) then
      return
   end

   for k,v in pairs(t) do
      for pat,label in pairs(styleT) do
	 if (k:find(pat)) then
            t[k] = label
            break
         end
      end
   end
end

local function hide_modules_hook(modT)
   -- modT is a table with: fullName, sn, fn and isVisible
   -- The latter is a boolean to determine if a module is visible or not

   dbg.start{"hide_modules_hook"}
   dbg.print{"Received modT: ", modT, "\n"}

   -- Read list of modules to hide from file specified in LMOD_HIDEMODSFILE env var
   local hidefile_name = os.getenv("LMOD_HIDEMODSFILE") or ""

   -- Use io.open with explicit lines iterator instead of io.lines to prevent
   -- crashing if file does not exist
   local hidefile = io.open(hidefile_name)

   if not hidefile then
      return nil
   end

   for modName in io.input(hidefile):lines() do
      -- Replace dashes in module name to prevent it to be interpreted as Lua pattern
      local modName_clean = modName:gsub("%-","_")
      local fullName_clean = modT.fullName:gsub("[%-]", "_")
      -- Prepend ^ to target module name to match only fullName beginning with the string
      if (fullName_clean:find("^" .. modName_clean)) then
         dbg.print{"Hiding module:", modT.fullName}
         modT.isVisible = false
      end
   end

   local hidelist = hidefile:read()
   hidefile:close()

   dbg.fini()
end

hook.register("avail", avail_labels_hook)
hook.register("isVisibleHook", hide_modules_hook)
